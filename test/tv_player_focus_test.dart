// Layer 2 of the dead remote: the video/live player page.
//
// `PlayerFocus` wraps the ENTIRE video page (not just the video surface):
// player, intro, related videos and the comment list all live inside it.
// It did two things that killed D-Pad navigation on that page outright:
//
//   1. `autofocus: true` — it grabs focus the moment the page opens, so the
//      seeded card focus is stolen by a node that is not a traversal target.
//   2. `_shouldHandle()` returned KeyEventResult.handled for tab + all four
//      arrows *unconditionally*, so every arrow press was swallowed before
//      Flutter's DirectionalFocusAction could move focus.
//
// Net effect on a TV: open any video and the remote is completely dead for
// the whole page — you cannot reach the comments, the related list, or even
// get back out. This is independent of the root focus scope fix.
//
// Desired behaviour:
//   * fullscreen  -> arrows are player controls (seek/volume). Unchanged.
//   * windowed + D-Pad mode -> arrows traverse the page so the user can
//     actually reach the rest of the content.
//   * touch/desktop (no D-Pad) -> completely unchanged from before.
import 'package:PiliPlus/utils/dpad_nav_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('windowed player in D-Pad mode: arrows must reach the page', () {
    test('arrow keys are released to focus traversal', () {
      for (final key in [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        expect(
          DpadNavPolicy.consumesNavKey(
            key,
            dpadMode: true,
            isFullScreen: false,
          ),
          isFalse,
          reason: '$key must traverse the page when the player is windowed, '
              'otherwise the remote is dead on the whole video page',
        );
      }
    });

    test('tab is released too', () {
      expect(
        DpadNavPolicy.consumesNavKey(
          LogicalKeyboardKey.tab,
          dpadMode: true,
          isFullScreen: false,
        ),
        isFalse,
      );
    });

    test('autofocus is off so it cannot steal the seeded card focus', () {
      expect(
        DpadNavPolicy.autofocus(dpadMode: true, isFullScreen: false),
        isFalse,
      );
    });
  });

  group('fullscreen player in D-Pad mode: arrows control playback', () {
    test('arrow keys stay with the player', () {
      for (final key in [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        expect(
          DpadNavPolicy.consumesNavKey(
            key,
            dpadMode: true,
            isFullScreen: true,
          ),
          isTrue,
          reason: '$key is seek/volume while fullscreen',
        );
      }
    });

    test('player keeps autofocus while fullscreen', () {
      expect(
        DpadNavPolicy.autofocus(dpadMode: true, isFullScreen: true),
        isTrue,
      );
    });
  });

  group('no D-Pad (phone / desktop): behaviour is unchanged', () {
    test('arrows and tab are still consumed by the player', () {
      for (final key in [
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        expect(
          DpadNavPolicy.consumesNavKey(
            key,
            dpadMode: false,
            isFullScreen: false,
          ),
          isTrue,
          reason: 'keyboard users must keep the existing player shortcuts',
        );
      }
    });

    test('autofocus is still on', () {
      expect(
        DpadNavPolicy.autofocus(dpadMode: false, isFullScreen: false),
        isTrue,
      );
    });
  });

  test('non-navigation keys are never affected by this policy', () {
    for (final key in [
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.enter,
    ]) {
      expect(
        DpadNavPolicy.consumesNavKey(
          key,
          dpadMode: true,
          isFullScreen: false,
        ),
        isFalse,
        reason: '$key is not a navigation key; the normal handler decides',
      );
    }
  });
}
