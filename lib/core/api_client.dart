import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'token_storage.dart';

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
            final refreshed = await _tryRefresh();
            if (refreshed) {
              final newToken = await storage.getAccessToken();
              req.extra['retried'] = true;
              req.headers['Authorization'] = 'Bearer $newToken';
              try {
                final clone = await _dio.fetch<dynamic>(req);
                return handler.resolve(clone);
              } on DioException catch (err) {
                return handler.next(err);
              }
            } else {
              await storage.clearTokens();
              onSessionExpired?.call();
            }
          }
          handler.next(e);
        },
      ),
    );
  }

  final TokenStorage storage;
  final void Function()? onSessionExpired;
  late final Dio _dio;

  Future<bool> _tryRefresh() async {
    final refresh = await storage.getRefreshToken();
    if (refresh == null || refresh.isEmpty) return false;
    try {
      final r = await _dio.post<dynamic>(
        '/auth/refresh',
        data: {'refreshToken': refresh},
        options: Options(extra: {'skipAuth': true}),
      );
      final data = r.data as Map;
      final access = data['accessToken'] as String?;
      final newRefresh = data['refreshToken'] as String?;
      if (access == null || newRefresh == null) return false;
      await storage.saveTokens(access: access, refresh: newRefresh);
      return true;
    } catch (_) {
      return false;
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
