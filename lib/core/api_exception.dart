import 'package:dio/dio.dart';

/// A normalized error surfaced to the UI. Carries the HTTP status (when known)
/// and a human-readable message extracted from the API's `{ error }` envelope.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isUnauthorized => statusCode == 401;
  bool get isNotFound => statusCode == 404;

  @override
  String toString() => message;

  /// Build an [ApiException] from a Dio error, preferring the server's
  /// `{ error: "..." }` message when present.
  factory ApiException.fromDio(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    String? serverMsg;
    if (data is Map && data['error'] is String) {
      serverMsg = data['error'] as String;
    }
    if (serverMsg != null) {
      return ApiException(serverMsg, statusCode: status);
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException('The server took too long to respond.', statusCode: status);
      case DioExceptionType.connectionError:
        return ApiException(
          'Could not reach the server. Check the server URL in Settings and that '
          'the backend is running.',
          statusCode: status,
        );
      default:
        return ApiException(
          status != null ? 'Request failed ($status).' : 'Network error.',
          statusCode: status,
        );
    }
  }
}
