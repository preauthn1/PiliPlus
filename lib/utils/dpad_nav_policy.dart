import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// Which screen-orientation policy applies.
enum ScreenOrientationMode {
  /// Landscape only. A TV / set-top box is physically landscape-only.
  landscape,

  /// All four orientations permitted (the app's "horizontal screen" setting).
  full,

  /// Portrait only (the phone default).
  portrait,
}

/// D-Pad navigation policy for the video/live player page.
///
/// Deliberately a **leaf** file: it imports nothing but `LogicalKeyboardKey`,
/// so it can be unit-tested without dragging the player controller (and its
/// whole dependency chain) into the test target.
///
/// Background — the second reason the remote appeared dead:
/// `PlayerFocus` wraps the ENTIRE video page (player, intro, related list,
/// comments), not just the video surface. It used to `autofocus: true` and
/// swallow tab + all four arrow keys unconditionally. On a TV that meant:
/// open any video, and focus was pinned inside a non-traversable node while
/// every arrow press was consumed before Flutter's `DirectionalFocusAction`
/// could run. The user could not reach the comments, the related videos, or
/// navigate back out — the page was a dead end.
abstract final class DpadNavPolicy {
  /// Keys the player historically treated as its own input.
  static bool isNavKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.tab ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown;

  /// Whether [key] should navigate backwards.
  ///
  /// A phone user swipes back; a remote user has only the BACK button. Most
  /// TV boxes deliver it as a system back event (handled by `PopScope`), but
  /// a substantial minority emit it as a plain key event instead, and nothing
  /// on mobile handled those — so the user could enter a page and not leave
  /// it, which reads as "the remote does nothing".
  ///
  /// Gated on [dpadMode] so a Bluetooth keyboard's `escape` never starts
  /// popping routes on a touch device.
  static bool isBackKey(LogicalKeyboardKey key, {required bool dpadMode}) {
    if (!dpadMode) return false;
    return key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack;
  }

  /// Whether the player should swallow [key] instead of letting focus
  /// traversal handle it.
  ///
  ///  * fullscreen — arrows are seek/volume, keep consuming them;
  ///  * windowed + D-Pad — release them so the remote can leave the player;
  ///  * no D-Pad (phone / desktop keyboard) — unchanged from before.
  static bool consumesNavKey(
    LogicalKeyboardKey key, {
    required bool dpadMode,
    required bool isFullScreen,
  }) {
    if (!isNavKey(key)) return false;
    if (dpadMode && !isFullScreen) return false;
    return true;
  }

  /// Whether the player should grab focus when the page opens.
  ///
  /// On a remote this must be off while windowed, otherwise it steals the
  /// focus that `TVFocusScope` seeded onto a real, traversable card, and the
  /// first D-Pad press appears to do nothing.
  static bool autofocus({
    required bool dpadMode,
    required bool isFullScreen,
  }) =>
      !dpadMode || isFullScreen;

  /// Orientation policy at startup and whenever D-Pad mode flips.
  ///
  /// A TV box is landscape-only. `full` is NOT a valid substitute: it permits
  /// all four orientations *including portrait*, which is exactly what makes
  /// the picture rotate/letterbox and the D-Pad directions stop matching
  /// on-screen geometry.
  static ScreenOrientationMode orientationFor({
    required bool dpadMode,
    required bool horizontalScreen,
  }) {
    if (dpadMode) return ScreenOrientationMode.landscape;
    return horizontalScreen
        ? ScreenOrientationMode.full
        : ScreenOrientationMode.portrait;
  }

  /// Orientation policy when a player is torn down.
  ///
  /// Same rule: on a remote, exiting a video must not re-permit portrait.
  static ScreenOrientationMode resetOrientationFor({
    required bool dpadMode,
    required bool horizontalScreen,
  }) =>
      orientationFor(dpadMode: dpadMode, horizontalScreen: horizontalScreen);
}
