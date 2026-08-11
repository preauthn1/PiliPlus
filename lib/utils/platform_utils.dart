import 'dart:io' show Platform;

abstract final class PlatformUtils {
  @pragma("vm:platform-const")
  static final bool isMobile = Platform.isAndroid || Platform.isIOS;

  @pragma("vm:platform-const")
  static final bool isDesktop =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @pragma("vm:platform-const")
  static final bool isDarwin = Platform.isIOS || Platform.isMacOS;

  // Android TV detection (runtime check needed)
  static bool? _isAndroidTV;
  static bool get isAndroidTV {
    if (_isAndroidTV != null) return _isAndroidTV!;
    // Will be set by platform channel on Android
    return false;
  }
  static void setAndroidTV(bool value) {
    _isAndroidTV = value;
  }

  static bool get isTV => Platform.isAndroid && isAndroidTV;
}
