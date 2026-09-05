// Verifies the actual defect that made the remote dead: that focus exists
// after startup, that D-Pad traversal moves between real cards, and that
// OK/Select activates the focused item.
//
// NOTE: TVFocusScope is a no-op unless PlatformUtils.isTV, so these tests
// set PlatformUtils.debugForceTV to simulate a TV device.
import 'package:PiliPlus/common/widgets/tv_focus_scope.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // isTV also requires Platform.isAndroid, which is false on the test host,
  // so force the TV branch explicitly.
  setUp(() => PlatformUtils.debugForceTV = true);
  tearDown(() => PlatformUtils.debugForceTV = null);

  Widget harness(List<String> tapped) {
    return MaterialApp(
      home: TVFocusScope(
        child: Scaffold(
          body: Column(
            children: [
              for (final label in ['a', 'b', 'c'])
                InkWell(
                  onTap: () => tapped.add(label),
                  child: SizedBox(height: 100, child: Text(label)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('focus is seeded after startup (was null -> dead remote)',
      (tester) async {
    await tester.pumpWidget(harness([]));
    await tester.pumpAndSettle();

    final focus = FocusManager.instance.primaryFocus;
    expect(focus, isNotNull);
    expect(focus is FocusScopeNode, isFalse,
        reason: 'a bare scope cannot be traversed from');
  });

  testWidgets('D-Pad down moves focus between cards', (tester) async {
    await tester.pumpWidget(harness([]));
    await tester.pumpAndSettle();

    final first = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final second = FocusManager.instance.primaryFocus;

    expect(second, isNotNull);
    expect(identical(first, second), isFalse,
        reason: 'arrow key should move focus to a different node');
  });

  testWidgets('OK/Select activates the focused card', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(harness(tapped));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(tapped, isNotEmpty,
        reason: 'select should activate the focused InkWell');
  });

  testWidgets('Enter also activates', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(harness(tapped));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(tapped, isNotEmpty);
  });

  testWidgets('re-seeds after focus is lost (route change scenario)',
      (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(harness(tapped));
    await tester.pumpAndSettle();

    // Simulate the tree losing focus, which previously made the remote
    // permanently unresponsive until app restart.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    // First press re-seeds (and is consumed)...
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNotNull);

    // ...and the remote is usable again.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tapped, isNotEmpty, reason: 'remote must recover, not stay dead');
  });

  testWidgets('non-TV devices are completely unaffected', (tester) async {
    PlatformUtils.debugForceTV = false;
    await tester.pumpWidget(harness([]));
    await tester.pumpAndSettle();

    // No auto-focus stealing on phones.
    final focus = FocusManager.instance.primaryFocus;
    expect(focus == null || focus is FocusScopeNode, isTrue,
        reason: 'phones should keep default focus behaviour');
  });
}
