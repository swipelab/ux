/// The running app's identity as the platform reports it.
class AppInfo {
  /// User-facing version string, e.g. `1.4.2`.
  final String version;

  /// Monotonic build counter behind [version].
  final int buildNumber;

  /// Binds a version / build pair.
  const AppInfo({required this.version, required this.buildNumber});
}
