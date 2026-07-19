/// App configuration — the API base URL.
///
/// Resolution order:
///   1. A value the user saved in Settings (persisted in TokenStorage).
///   2. A compile-time default via `--dart-define=FOCUSFLOW_BASE_URL=...`.
///   3. The built-in default below.
///
/// Default targets the Next.js dev server as seen from the Android emulator:
/// the host machine's `localhost` is reachable at `10.0.2.2` from inside the
/// emulator. On a physical device, set your machine's LAN IP in Settings
/// (e.g. http://192.168.1.20:3000).
class AppConfig {
  AppConfig({required this.baseUrl});

  /// The origin (scheme + host + port), WITHOUT the `/api/v1` suffix.
  final String baseUrl;

  static const String _compileTimeDefault =
      String.fromEnvironment('FOCUSFLOW_BASE_URL', defaultValue: 'http://10.0.2.2:3000');

  static String get fallbackBaseUrl => _compileTimeDefault;

  /// The full API prefix used by the Dio client.
  String get apiBase => '${_stripTrailingSlash(baseUrl)}/api/v1';

  static String _stripTrailingSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  /// Basic sanity check for a user-entered origin.
  static bool isValidOrigin(String s) {
    final uri = Uri.tryParse(s.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
  }
}
