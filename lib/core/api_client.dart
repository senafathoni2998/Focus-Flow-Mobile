import 'dart:async';

import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'response_cache.dart';
import 'token_storage.dart';

/// Outcome of a token-refresh attempt. `networkError` must NOT sign the user out
/// (a transient blip shouldn't kill a valid session); only `authFailed` does.
enum _RefreshOutcome { refreshed, authFailed, networkError }

/// Thin wrapper around Dio that:
///  - prefixes every path with the `/api/v1` base,
///  - attaches the bearer access token to authenticated requests,
///  - transparently refreshes the token once on a 401 and retries, and
///  - signals [onSessionExpired] when refresh fails (so the app can log out).
///
/// Requests that must NOT carry (or refresh) auth — login/register/refresh —
/// pass `skipAuth: true`.
class ApiClient {
  ApiClient({
    required this.storage,
    required String apiBase,
    this.onSessionExpired,
    this.cache,
    this.onServingCache,
    this.onNetworkOk,
  }) {
    final options = BaseOptions(
      baseUrl: apiBase,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'Content-Type': 'application/json'},
      // We interpret non-2xx ourselves via DioException.
    );
    _dio = Dio(options);

    // A SECOND Dio with NO interceptors, used for the refresh call and for
    // replaying a request after a refresh.
    //
    // Both of those happen from inside the QueuedInterceptorsWrapper's onError
    // handler, which holds the error queue while it awaits. Issuing them on `_dio`
    // sent their own failures back into that same blocked queue, so any refresh
    // that returned non-2xx (expired refresh token, rotated NEXTAUTH_SECRET)
    // deadlocked: the request never completed, the `authFailed` branch below was
    // never reached, clearTokens() never ran, and the app sat on its splash
    // spinner forever with Clear app data as the only way out.
    _bare = Dio(options);

    // QueuedInterceptors process one handler at a time, so a burst of parallel
    // 401s triggers a single refresh rather than a stampede.
    _dio.interceptors.add(
      QueuedInterceptorsWrapper(
        onRequest: (options, handler) async {
          final skipAuth = options.extra['skipAuth'] == true;
          if (!skipAuth) {
            final token = await storage.getAccessToken();
            if (token != null && token.isNotEmpty) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          final status = e.response?.statusCode;
          final req = e.requestOptions;
          final isAuthCall = req.extra['skipAuth'] == true;
          final alreadyRetried = req.extra['retried'] == true;

          if (status == 401 && !isAuthCall && !alreadyRetried) {
            // If a concurrent request already refreshed the token, just retry with
            // the current one instead of refreshing again (avoids a stampede).
            final current = await storage.getAccessToken();
            if (current != null &&
                current.isNotEmpty &&
                req.headers['Authorization'] != 'Bearer $current') {
              return _retryWith(req, current, handler);
            }
            final result = await _tryRefresh();
            if (result == _RefreshOutcome.refreshed) {
              return _retryWith(req, await storage.getAccessToken(), handler);
            } else if (result == _RefreshOutcome.authFailed) {
              await storage.clearTokens();
              onSessionExpired?.call();
            }
            // networkError → propagate the original error, keep the session.
          }
          handler.next(e);
        },
      ),
    );
  }

  final TokenStorage storage;
  final void Function()? onSessionExpired;

  /// Optional read-through cache. When present, successful GETs are stored and
  /// replayed if the network later fails.
  final ResponseCache? cache;

  /// Told true when a response came from disk instead of the server, and false
  /// as soon as a live one succeeds — so the UI can say which it is showing.
  final void Function(bool servingCache)? onServingCache;

  /// Fired on every 2xx from any verb.
  ///
  /// The offline write queue uses it as a free connectivity signal: the moment
  /// anything reaches the server, there is a network again and the queue can
  /// drain. That is why no connectivity package is needed — link state would
  /// report "connected" behind a captive portal or against a LAN backend that
  /// is down, which is exactly the case this app hits.
  final void Function()? onNetworkOk;

  late final Dio _dio;
  late final Dio _bare;
  /// Single-flight guard: concurrent 401s share one refresh instead of racing.
  Future<_RefreshOutcome>? _inFlightRefresh;

  /// Retry a request with a (possibly refreshed) token, marking it so it won't
  /// loop back into the refresh branch.
  Future<void> _retryWith(
    RequestOptions req,
    String? token,
    ErrorInterceptorHandler handler,
  ) async {
    req.extra['retried'] = true;
    if (token != null && token.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    try {
      // `_bare`, not `_dio`: we are inside the error queue, and a replay that
      // fails on `_dio` would re-enter that blocked queue and hang. The header is
      // set explicitly above, so the absent onRequest interceptor costs nothing.
      handler.resolve(await _bare.fetch<dynamic>(req));
    } on DioException catch (err) {
      handler.next(err);
    }
  }

  Future<_RefreshOutcome> _tryRefresh() {
    // Collapse concurrent callers onto one in-flight refresh.
    return _inFlightRefresh ??= _refreshOnce().whenComplete(() {
      _inFlightRefresh = null;
    });
  }

  Future<_RefreshOutcome> _refreshOnce() async {
    final refresh = await storage.getRefreshToken();
    if (refresh == null || refresh.isEmpty) return _RefreshOutcome.authFailed;
    try {
      // `_bare` so a non-2xx refresh cannot deadlock the error queue we are in.
      final r = await _bare.post<dynamic>(
        '/auth/refresh',
        data: {'refreshToken': refresh},
        options: Options(extra: {'skipAuth': true}),
      );
      final data = r.data as Map;
      final access = data['accessToken'] as String?;
      final newRefresh = data['refreshToken'] as String?;
      if (access == null || newRefresh == null) return _RefreshOutcome.authFailed;
      await storage.saveTokens(access: access, refresh: newRefresh);
      return _RefreshOutcome.refreshed;
    } on DioException catch (err) {
      final s = err.response?.statusCode;
      // A 4xx means the refresh token itself is bad → sign out. No response (or a
      // 5xx) is a transient/network failure → keep the session, don't sign out.
      if (s != null && s >= 400 && s < 500) return _RefreshOutcome.authFailed;
      return _RefreshOutcome.networkError;
    } catch (_) {
      return _RefreshOutcome.networkError;
    }
  }

  // ---- JSON helpers -----------------------------------------------------------

  /// Reject a 2xx whose body is not JSON.
  ///
  /// Dio only decodes when the content-type says JSON, so a misconfigured reverse
  /// proxy answering `/api/v1/tasks` with the Next.js HTML page came back as a
  /// 200 carrying a String. That fell through `asMap` -> `{}` -> `asMapList` ->
  /// `[]`, and every list screen rendered its "nothing here" empty state with no
  /// error and no retry — indistinguishable from genuinely having no data.
  ///
  /// The status is carried through deliberately. This used to throw with
  /// `statusCode: null`, which the write queue would read as "no answer at all"
  /// — a transport failure, which by design consumes no retry budget. It would
  /// therefore have retried forever a request that had in fact SUCCEEDED.
  dynamic _requireJson(dynamic data, int? status) {
    if (data == null || data is Map || data is List) return data;
    throw ApiException(
      'The server returned an unexpected (non-JSON) response. Check the server '
      'URL in Settings — it should point at the FocusFlow backend root.',
      statusCode: status,
      hadResponse: true,
    );
  }

  /// Cache key: path plus its query, since `/sessions?days=7` and
  /// `/sessions?days=30` are different resources.
  String _cacheKey(String path, Map<String, dynamic>? query) {
    if (query == null || query.isEmpty) return path;
    // Sorted, so the same query written in a different order is one cache entry.
    final parts = query.entries.map((e) => '${e.key}=${e.value}').toList()..sort();
    return '$path?${parts.join('&')}';
  }

  Future<dynamic> getJson(String path, {Map<String, dynamic>? query}) async {
    final key = _cacheKey(path, query);
    try {
      final r = await _dio.get<dynamic>(path, queryParameters: query);
      final data = _requireJson(r.data, r.statusCode);
      // Only successful, well-formed responses are worth keeping.
      unawaited(cache?.write(key, data) ?? Future.value());
      onServingCache?.call(false);
      onNetworkOk?.call();
      return data;
    } on DioException catch (e) {
      // Fall back to disk ONLY for transport failures. A 4xx is the server
      // answering — serving stale data over a 401 or a 404 would hide a real
      // problem behind data that looks fine.
      if (cache != null && _isTransport(e)) {
        final cached = await cache!.read(key);
        if (cached != null) {
          onServingCache?.call(true);
          return cached;
        }
      }
      throw ApiException.fromDio(e);
    }
  }

  /// True when the request never got an answer, as opposed to getting a bad one.
  bool _isTransport(DioException e) {
    if (e.response != null) return false;
    return e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.unknown;
  }

  Future<dynamic> postJson(
    String path, {
    Object? body,
    bool skipAuth = false,
    String? idempotencyKey,
  }) async {
    try {
      final r = await _dio.post<dynamic>(
        path,
        data: body,
        options: Options(
          extra: skipAuth ? {'skipAuth': true} : null,
          headers: idempotencyKey == null
              ? null
              : {_idempotencyHeader: idempotencyKey},
        ),
      );
      onNetworkOk?.call();
      return _requireJson(r.data, r.statusCode);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<dynamic> patchJson(String path, {Object? body}) async {
    try {
      final r = await _dio.patch<dynamic>(path, data: body);
      onNetworkOk?.call();
      return _requireJson(r.data, r.statusCode);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<dynamic> deleteJson(String path, {Object? body}) async {
    try {
      final r = await _dio.delete<dynamic>(path, data: body);
      onNetworkOk?.call();
      return _requireJson(r.data, r.statusCode);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  static const String _idempotencyHeader = 'Idempotency-Key';

  /// Send one queued write exactly as the queue described it.
  ///
  /// Deliberately verb-agnostic: the queue stores a method and a path, and this
  /// replays them without knowing what the operation means. Anything that
  /// interpreted the op here would be a second place the queue's semantics live.
  /// Returns the real status alongside the body — the queue classifies on the
  /// status, so collapsing 201 and 200 here would hide information it needs.
  Future<({int? status, dynamic data})> sendQueued({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    String? idempotencyKey,
  }) async {
    try {
      final r = await _dio.request<dynamic>(
        path,
        data: body,
        options: Options(
          method: method,
          headers: idempotencyKey == null
              ? null
              : {_idempotencyHeader: idempotencyKey},
        ),
      );
      onNetworkOk?.call();
      return (status: r.statusCode, data: _requireJson(r.data, r.statusCode));
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}
