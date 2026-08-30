/// Backend base URL, injected at build/run time so switching between a LAN
/// IP and a hosted test host is a flag, not a code change.
///
/// Usage: flutter run --dart-define=API_BASE_URL=http://192.168.1.23:8000
const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);
