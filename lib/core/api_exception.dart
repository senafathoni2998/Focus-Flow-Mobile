import 'package:dio/dio.dart';

/// A normalized error surfaced to the UI. Carries the HTTP status (when known)
/// and a human-readable message extracted from the API's `{ error }` envelope.
class ApiException implements Exception {
  ApiException(
    this.message, {
    this.statusCode,
    this.hadResponse = false,
    this.retryAfterSeconds,
  });

  final String message;
  final int? statusCode;

  /// Whether the server answered at all.
  ///
  /// NOT the same as `statusCode != null`, and the offline write queue turns on
  /// the difference: "never got an answer" is a transport failure that must not
  /// consume a retry budget, while "answered badly" must. A 2xx carrying a
  /// non-JSON body has no status worth classifying by but definitely got an
  /// answer — calling that transport would retry, unbudgeted and forever, a
  /// request that actually succeeded.
  final bool hadResponse;

  /// From the `Retry-After` header. The API sets it on the 409 meaning "a
  /// request with this Idempotency-Key is still in progress".
  final int? retryAfterSeconds;

  bool get isUnauthorized => statusCode == 401;
  bool get isNotFound => statusCode == 404;

  @override
  String toString() => message;

  /// Build an [ApiException] from a Dio error, preferring the server's
  /// `{ error: "..." }` message when present.
  factory ApiException.fromDio(DioException e) {
    final Response<dynamic>? response = e.response;
    final int? status = response?.statusCode;
    final bool hadResponse = response != null;
    final int? retryAfter = _retryAfter(response);
    final dynamic data = response?.data;
    String? serverMsg;
    if (data is Map && data['error'] is String) {
      serverMsg = data['error'] as String;
    }
    // A redirect is never a legitimate answer from `/api/v1/*`, and the client
    // no longer follows one (see ApiClient's followRedirects). Handled BEFORE
    // the server's own message, because a generic "Request failed (308)" gives
    // no clue what to change — the one realistic cause is a proxy upgrading
    // http to https, and the fix is to use https in Settings.
    if (status != null && status >= 300 && status < 400) {
      final String? location = response?.headers.value('location');
      return ApiException(
        location == null
            ? 'The server redirected the request ($status). Check the server URL in Settings.'
            : 'The server redirected to $location — use that address in Settings instead.',
        statusCode: status,
        hadResponse: hadResponse,
        retryAfterSeconds: retryAfter,
      );
    }

    if (serverMsg != null) {
      return ApiException(
        serverMsg,
        statusCode: status,
        hadResponse: hadResponse,
        retryAfterSeconds: retryAfter,
      );
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException(
          'The server took too long to respond.',
          statusCode: status,
          hadResponse: hadResponse,
          retryAfterSeconds: retryAfter,
        );
      case DioExceptionType.connectionError:
        return ApiException(
          'Could not reach the server. Check the server URL in Settings and that '
          'the backend is running.',
          statusCode: status,
          hadResponse: hadResponse,
          retryAfterSeconds: retryAfter,
        );
      default:
        return ApiException(
          status != null ? 'Request failed ($status).' : 'Network error.',
          statusCode: status,
          hadResponse: hadResponse,
          retryAfterSeconds: retryAfter,
        );
    }
  }

  static int? _retryAfter(Response<dynamic>? response) {
    final String? raw = response?.headers.value('retry-after');
    if (raw == null) return null;
    return int.tryParse(raw.trim());
  }
}
