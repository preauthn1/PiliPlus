// Layer 3 & 4: orientation, and the mid-session flip.
//
// Two defects that both keep the "remote does nothing sensible" symptom
// alive even once focus works:
//
// 1. Orientation is decided ONCE in main(), before any key has arrived. On a
//    box where detection fails, dpadMode is false at that moment, so the app
//    pins portraitUp on a landscape-only device. When the user then presses a
//    D-Pad key, dpadMode flips on — but nothing re-applies the orientation,
//    so the picture stays rotated/cropped for the rest of the session and the
//    arrow directions no longer match on-screen geometry.
//
// 2. `PlPlayerController.resetScreenRotation()` runs on every player dispose
//    and used `horizontalScreen ? fullMode() : portraitUpMode()`. `fullMode()`
//    permits ALL FOUR orientations including portrait, so exiting any video
//    let a TV drop back to portrait. TVs are landscape-only.
import 'package:PiliPlus/utils/dpad_nav_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('startup / mid-session orientation', () {
    test('D-Pad mode pins landscape, never "full" (which allows portrait)', () {
      expect(
        DpadNavPolicy.orientationFor(dpadMode: true, horizontalScreen: false),
        ScreenOrientationMode.landscape,
      );
      expect(
        DpadNavPolicy.orientationFor(dpadMode: true, horizontalScreen: true),
        ScreenOrientationMode.landscape,
        reason: 'a TV is landscape-only; "full" would re-permit portrait',
      );
    });

    test('phones keep their existing behaviour exactly', () {
      expect(
        DpadNavPolicy.orientationFor(dpadMode: false, horizontalScreen: true),
        ScreenOrientationMode.full,
      );
      expect(
        DpadNavPolicy.orientationFor(dpadMode: false, horizontalScreen: false),
        ScreenOrientationMode.portrait,
      );
    });
  });

  group('player teardown orientation reset', () {
    test('D-Pad: exiting a video must NOT re-allow portrait', () {
      expect(
        DpadNavPolicy.resetOrientationFor(
          dpadMode: true,
          horizontalScreen: true,
        ),
        ScreenOrientationMode.landscape,
        reason: 'fullMode() here let a TV rotate to portrait after every video',
      );
    });

    test('phone: unchanged (full when horizontal, portrait otherwise)', () {
      expect(
        DpadNavPolicy.resetOrientationFor(
          dpadMode: false,
          horizontalScreen: true,
        ),
        ScreenOrientationMode.full,
      );
      expect(
        DpadNavPolicy.resetOrientationFor(
          dpadMode: false,
          horizontalScreen: false,
        ),
        ScreenOrientationMode.portrait,
      );
    });
  });
}
