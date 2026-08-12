import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

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
  // channel (see MainActivity.kt).
  static bool _isAndroidTV = false;
  static bool _tvResolved = false;

  static bool get isAndroidTV => _isAndroidTV;

  /// Whether the native TV probe has completed.
  static bool get isTVResolved => _tvResolved;

  static void setAndroidTV(bool value) {
    _isAndroidTV = value;
    _tvResolved = true;
    if (value) _enableDpad('native detection');
  }

  /// Test-only override.
  @visibleForTesting
  static bool? debugForceTV;

  /// Result of the native probe only. Prefer [dpadMode] for anything that
  /// drives remote-control behaviour.
  static bool get isTV => debugForceTV ?? (Platform.isAndroid && _isAndroidTV);

  // ---------------------------------------------------------------------
  // D-Pad mode
  // ---------------------------------------------------------------------
  //
  // Device detection is a heuristic and it FAILS on many CN TV boxes and
  // projectors: they report UI_MODE_TYPE_NORMAL, do not expose
  // FEATURE_LEANBACK as a system feature, and still advertise
  // FEATURE_TOUCHSCREEN. When it failed, every TV feature silently became a
  // no-op and the remote appeared completely dead.
  //
  // So we no longer rely on detection alone. An actual D-Pad key event is
  // ground truth: if arrow/select keys are arriving, the user is on a remote,
  // whatever the device claims to be. [TVFocusScope] flips this on the first
  // such event, and the user can also force it in settings.

  /// Notifies when D-Pad mode turns on so widgets can restyle themselves.
  static final ValueNotifier<bool> dpadModeNotifier = ValueNotifier<bool>(false);

  static bool _userForcedDpad = false;

  /// True when the app should behave as a TV/remote UI.
  ///
  /// This is what focus highlighting and remote handling must check —
  /// **not** [isTV].
  static bool get dpadMode =>
      debugForceTV ?? (dpadModeNotifier.value || _userForcedDpad);

  static void _enableDpad(String reason) {
    if (dpadModeNotifier.value) return;
    debugPrint('D-Pad mode enabled ($reason)');
    dpadModeNotifier.value = true;
  }

  /// Called when a real directional/select key is observed.
  static void reportDpadKey() => _enableDpad('hardware key event');

  /// Manual override from settings, for devices whose detection fails and
  /// which somehow never emit a recognised key.
  static void setForceDpad(bool value) {
    _userForcedDpad = value;
    if (value) {
      _enableDpad('user setting');
    } else {
      dpadModeNotifier.value = false;
    }
  }

  static bool get isDpadForcedByUser => _userForcedDpad;
}
