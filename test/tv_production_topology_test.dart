// Why the remote was STILL dead after three "fixes".
//
// Every previous TV test mounted the scope as
//     MaterialApp(home: TVFocusScope(child: ...))
// i.e. BELOW the Navigator. Production mounts it in `MaterialApp.builder`
// (main.dart `_builder`), i.e. ABOVE the Navigator:
//     MaterialApp(builder: (ctx, child) => TVFocusScope(child: child!))
//
// That single structural difference changes what `_rootNode.nearestScope`
// resolves to:
//   * below the Navigator -> the route's ModalScope, whose `focusedChild`
//     starts null, so seeding falls through to a real widget node. Green.
//   * above the Navigator -> the app root scope, whose `focusedChild` is the
//     "Navigator Scope" FocusScopeNode. That node passes the old
//     `_isFocusable` screen (it has a laid-out RenderSemanticsAnnotations),
//     so seeding focused a *scope*. `_focusIsEmpty` treats a FocusScopeNode
//     as empty, so the next press re-seeded the same scope, returned
//     KeyEventResult.handled, and consumed the key. Forever.
//
// Net effect on the user's box: every single D-Pad press was swallowed and
// focus never landed on anything. "遥控板怎么按都没有反应".
//
// These tests run in the PRODUCTION topology.
import 'package:PiliPlus/common/widgets/tv_card.dart';
import 'package:PiliPlus/common/widgets/tv_focus_scope.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    // Device where native detection FAILED — the field condition.
    PlatformUtils.debugForceTV = null;
    PlatformUtils.setAndroidTV(false);
    PlatformUtils.setForceDpad(false);
  });

  tearDown(() {
    PlatformUtils.debugForceTV = null;
    PlatformUtils.setForceDpad(false);
  });

  /// Mirrors main.dart: TVFocusScope installed via `builder`, above Navigator.
  Widget productionApp(List<String> tapped) => MaterialApp(
        builder: (context, child) => TVFocusScope(child: child!),
        home: Scaffold(
          body: ListView(
            children: [
              for (final label in ['a', 'b', 'c', 'd'])
                TVFocusHighlight(
                  child: InkWell(
                    onTap: () => tapped.add(label),
                    child: SizedBox(height: 100, child: Text(label)),
                  ),
                ),
            ],
          ),
        ),
      );

  testWidgets(
      'production topology: first D-Pad press lands focus on a real widget',
      (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(productionApp(tapped));
    await tester.pumpAndSettle();

    expect(PlatformUtils.dpadMode, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(PlatformUtils.dpadMode, isTrue,
        reason: 'the key probe must still fire above the Navigator');

    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    expect(focused, isNot(isA<FocusScopeNode>()),
        reason: 'seeding a FocusScopeNode leaves the tree "empty" forever, '
            'so every later press is consumed and the remote stays dead');
  });

  testWidgets('production topology: the second press actually moves focus',
      (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(productionApp(tapped));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final first = FocusManager.instance.primaryFocus;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final second = FocusManager.instance.primaryFocus;

    expect(second, isNot(isA<FocusScopeNode>()));
    expect(identical(first, second), isFalse,
        reason: 'D-Pad must traverse, not re-seed the same node');
  });

  testWidgets('production topology: OK activates the focused item',
      (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(productionApp(tapped));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(tapped, isNotEmpty,
        reason: 'OK/Select must open the focused card in production topology');
  });

  testWidgets('production topology: focus survives a route push and pop',
      (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(productionApp(tapped));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Column(
            children: [
              for (final label in ['x', 'y'])
                InkWell(
                  onTap: () => tapped.add(label),
                  child: SizedBox(height: 80, child: Text(label)),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A fresh route usually starts with nothing focused. The remote must
    // recover within a couple of presses, not go permanently dead.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNot(isA<FocusScopeNode>()),
        reason: 'after a route push the remote must not be dead');

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tapped.any((e) => e == 'x' || e == 'y'), isTrue,
        reason: 'OK must activate something on the NEW route');
  });

  testWidgets('a FocusScopeNode is never accepted as a seed target',
      (tester) async {
    // Direct unit-level guard on the screening predicate: whatever else
    // changes, a scope node must never be chosen, because focusing one is
    // indistinguishable from "no focus" for D-Pad traversal.
    final scope = FocusScopeNode(debugLabel: 'probe scope');
    addTearDown(scope.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: FocusScope(
          node: scope,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(TVFocusScope.debugIsSeedable(scope), isFalse,
        reason: 'scope nodes are not traversable origins');
  });
}
