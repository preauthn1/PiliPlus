// Layer 5: getting back OUT of a page with a remote.
//
// A phone user swipes back; a TV user has only the remote's BACK button.
// Most Android TV boxes deliver it as a system back event (handled by
// PopScope), but a substantial minority emit it as a plain key event —
// `goBack` (Android KEYCODE_BACK mapped as a browser/media key) or `escape`.
// Neither had a handler anywhere on mobile: `BackDetector` handles `escape`
// but is only mounted on DESKTOP (main.dart `_builder`).
//
// Consequence on such a box: the user navigates into a video or a settings
// page and cannot leave it. That is indistinguishable from "遥控器没反应".
//
// Guardrails encoded here: this must never fire on a phone. `escape` from a
// Bluetooth keyboard must not start popping routes on a touch device, so the
// whole path is gated on D-Pad mode.
import 'package:PiliPlus/utils/dpad_nav_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('D-Pad mode: back/escape are treated as "go back"', () {
    for (final key in [
      LogicalKeyboardKey.goBack,
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.browserBack,
    ]) {
      expect(
        DpadNavPolicy.isBackKey(key, dpadMode: true),
        isTrue,
        reason: '$key must be able to leave a page on a remote',
      );
    }
  });

  test('no D-Pad: back keys are NOT intercepted', () {
    for (final key in [
      LogicalKeyboardKey.goBack,
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.browserBack,
    ]) {
      expect(
        DpadNavPolicy.isBackKey(key, dpadMode: false),
        isFalse,
        reason: 'a Bluetooth keyboard on a phone must not pop routes',
      );
    }
  });

  test('ordinary keys are never treated as back', () {
    for (final key in [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.keyB,
    ]) {
      expect(DpadNavPolicy.isBackKey(key, dpadMode: true), isFalse,
          reason: '$key must not navigate backwards');
    }
  });
}
