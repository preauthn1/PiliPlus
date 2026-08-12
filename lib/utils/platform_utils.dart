import 'dart:io' show Platform;

abstract final class PlatformUtils {
  @pragma("vm:platform-const")
  static final bool isMobile = Platform.isAndroid || Platform.isIOS;

  @pragma("vm:platform-const")
  static final bool isDesktop =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @pragma("vm:platform-const")
  static final bool isDarwin = Platform.isIOS || Platform.isMacOS;

  // Android TV detection.
  //
  // Resolved once at startup by [setAndroidTV] via the native platform
  // channel (see MainActivity.kt). Until that resolves this reports false,
  // so anything that depends on TV mode must run after main()'s detection.
  static bool _isAndroidTV = false;
  static bool _tvResolved = false;

  static bool get isAndroidTV => _isAndroidTV;

  /// Whether the native TV probe has completed. Used to avoid caching a
  /// premature `false` in long-lived widgets.
  static bool get isTVResolved => _tvResolved;

  static void setAndroidTV(bool value) {
    _isAndroidTV = value;
    _tvResolved = true;
  }

  static bool get isTV => Platform.isAndroid && _isAndroidTV;
}
