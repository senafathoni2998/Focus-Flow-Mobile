import 'package:dio/dio.dart';

import 'api_exception.dart';
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
  }) {
    _dio = Dio(
      BaseOptions(
        baseUrl: apiBase,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'Content-Type': 'application/json'},
        // We interpret non-2xx ourselves via DioException.
      ),
    );

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
  late final Dio _dio;

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
      handler.resolve(await _dio.fetch<dynamic>(req));
    } on DioException catch (err) {
      handler.next(err);
    }
  }

  Future<_RefreshOutcome> _tryRefresh() async {
    final refresh = await storage.getRefreshToken();
    if (refresh == null || refresh.isEmpty) return _RefreshOutcome.authFailed;
    try {
      final r = await _dio.post<dynamic>(
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

  Future<dynamic> getJson(String path, {Map<String, dynamic>? query}) async {
    try {
      final r = await _dio.get<dynamic>(path, queryParameters: query);
      return r.data;
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<dynamic> postJson(String path, {Object? body, bool skipAuth = false}) async {
    try {
      final r = await _dio.post<dynamic>(
        path,
        data: body,
        options: skipAuth ? Options(extra: {'skipAuth': true}) : null,
      );
      return r.data;
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<dynamic> patchJson(String path, {Object? body}) async {
    try {
      final r = await _dio.patch<dynamic>(path, data: body);
      return r.data;
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<dynamic> deleteJson(String path, {Object? body}) async {
    try {
      final r = await _dio.delete<dynamic>(path, data: body);
      return r.data;
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}
