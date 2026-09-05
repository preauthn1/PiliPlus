// The failure the user actually hit: on their TV box, native detection
// returned false (UI mode NORMAL, no FEATURE_LEANBACK, touchscreen still
// advertised). Every TV feature was gated behind PlatformUtils.isTV, so
// the focus scope was never even mounted -> remote completely dead, with
// no way for the user to recover.
//
// These tests pin the recovery contract: a real D-Pad key must switch the
// app into remote mode by itself, WITHOUT any successful detection.
import 'package:PiliPlus/common/widgets/tv_card.dart';
import 'package:PiliPlus/common/widgets/tv_focus_scope.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    // Simulate a device where detection FAILED.
    PlatformUtils.debugForceTV = null;
    PlatformUtils.setAndroidTV(false);
    PlatformUtils.setForceDpad(false);
  });

  tearDown(() {
    PlatformUtils.debugForceTV = null;
    PlatformUtils.setForceDpad(false);
  });

  Widget harness(List<String> tapped) => MaterialApp(
        home: TVFocusScope(
          child: Scaffold(
            body: Column(
              children: [
                for (final label in ['a', 'b', 'c'])
                  TVFocusHighlight(
                    child: InkWell(
                      onTap: () => tapped.add(label),
                      child: SizedBox(height: 100, child: Text(label)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

  testWidgets('detection failed: D-Pad key alone enables remote mode',
      (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(harness(tapped));
    await tester.pumpAndSettle();

    // Precondition: app does NOT think it is a TV.
    expect(PlatformUtils.isTV, isFalse);
    expect(PlatformUtils.dpadMode, isFalse);
    // MaterialApp's ModalScope always owns a FocusScopeNode; what matters is
    // that no real widget node has been given focus yet.
    expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>(),
        reason: 'no focus stealing before any D-Pad evidence');

    // User presses DOWN on the remote — this is the ground truth.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(PlatformUtils.dpadMode, isTrue,
        reason: 'a real D-Pad key must enable remote mode by itself');
    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(FocusManager.instance.primaryFocus is FocusScopeNode, isFalse);
  });

  testWidgets('detection failed: remote becomes fully usable after 1st press',
      (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(harness(tapped));
    await tester.pumpAndSettle();

    // 1st press: enables mode + seeds focus (consumed).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final first = FocusManager.instance.primaryFocus;

    // 2nd press: must actually move.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(identical(first, FocusManager.instance.primaryFocus), isFalse,
        reason: 'focus must move on the following press');

    // OK must activate.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tapped, isNotEmpty, reason: 'OK/Select must open the focused item');
  });

  testWidgets('select key alone (no arrows) also enables remote mode',
      (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(harness(tapped));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(PlatformUtils.dpadMode, isTrue);
  });

  testWidgets('manual settings override enables remote mode', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(harness(tapped));
    await tester.pumpAndSettle();
    expect(PlatformUtils.dpadMode, isFalse);

    // User flips the "电视遥控模式" switch.
    PlatformUtils.setForceDpad(true);
    await tester.pumpAndSettle();

    expect(PlatformUtils.dpadMode, isTrue);
    expect(FocusManager.instance.primaryFocus, isNotNull,
        reason: 'enabling the switch must seed focus immediately');
  });

  testWidgets('a touch device is not switched into TV mode by typing',
      (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(harness(tapped));
    await tester.pumpAndSettle();

    // Enter/letters are NOT D-Pad evidence (a BT keyboard sends these).
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(PlatformUtils.dpadMode, isFalse,
        reason: 'typing must not turn a phone into TV mode');
  });

  testWidgets('focus highlight appears once remote mode turns on',
      (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(harness(tapped));
    await tester.pumpAndSettle();

    // Before: TVFocusHighlight is a pass-through, so no AnimatedScale.
    expect(find.byType(AnimatedScale), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    // After: highlight wrappers are live.
    expect(find.byType(AnimatedScale), findsWidgets,
        reason: 'cards must show focus decoration in remote mode');
  });
}
