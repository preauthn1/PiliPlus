// Reproduces the on-device crash burst:
//   Bad state: RenderBox was not laid out: RenderSemanticsAnnotations#...
//   Null check operator used on a null value
//
// Root cause: FocusTraversalPolicy.defaultTraversalRequestFocusCallback does
// `node.context!` + `Scrollable.ensureVisible(...)` unconditionally. A focus
// node that is detached (context == null) or attached-but-not-laid-out makes
// it throw. TVFocusScope installs a screened replacement.
import 'package:PiliPlus/common/widgets/tv_focus_scope.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => PlatformUtils.debugForceTV = true);
  tearDown(() => PlatformUtils.debugForceTV = null);

  test('BASELINE: Flutter default callback throws on a detached node', () {
    final orphan = FocusNode(); // never attached -> context == null
    addTearDown(orphan.dispose);

    expect(
      () => FocusTraversalPolicy.defaultTraversalRequestFocusCallback(orphan),
      throwsA(anything),
      reason: 'this is the crash users hit; if this ever stops throwing, '
          'the upstream bug was fixed and the workaround can be revisited',
    );
  });

  test('TVFocusScope safe callback does NOT throw on a detached node', () {
    final orphan = FocusNode();
    addTearDown(orphan.dispose);

    expect(
      () => TVFocusScope.debugSafeRequestFocus(orphan),
      returnsNormally,
    );
  });

  testWidgets('safe callback still scrolls a laid-out node into view',
      (tester) async {
    final controller = ScrollController();
    final targetFocus = FocusNode();
    addTearDown(() {
      controller.dispose();
      targetFocus.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              const SizedBox(height: 2000),
              Focus(
                focusNode: targetFocus,
                child: const SizedBox(height: 100, child: Text('target')),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Scroll the target into the build/layout window first.
    controller.jumpTo(1900);
    await tester.pumpAndSettle();
    expect(controller.offset, 1900);

    TVFocusScope.debugSafeRequestFocus(targetFocus);
    await tester.pumpAndSettle();

    expect(targetFocus.hasFocus, isTrue);
    expect(controller.offset, isNot(1900),
        reason: 'ensureVisible must still run for laid-out nodes');
  });

  testWidgets('D-Pad traversal through a long lazy list does not throw',
      (tester) async {
    final errors = <String>[];
    final prev = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString());
    addTearDown(() => FlutterError.onError = prev);

    await tester.pumpWidget(
      MaterialApp(
        home: TVFocusScope(
          child: Scaffold(
            body: ListView.builder(
              itemCount: 300,
              itemBuilder: (context, i) => InkWell(
                onTap: () {},
                child: SizedBox(height: 120, child: Text('item $i')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var i = 0; i < 60; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(errors, isEmpty,
        reason: 'D-Pad traversal threw:\n${errors.take(3).join("\n---\n")}');
  });

  testWidgets('seeding never focuses an unlaid-out node', (tester) async {
    final errors = <String>[];
    final prev = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString());
    addTearDown(() => FlutterError.onError = prev);

    await tester.pumpWidget(
      MaterialApp(
        home: TVFocusScope(
          child: Scaffold(
            body: ListView.builder(
              itemCount: 300,
              itemBuilder: (context, i) => InkWell(
                onTap: () {},
                child: SizedBox(height: 120, child: Text('item $i')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    final ro = focused!.context?.findRenderObject();
    expect(ro, isA<RenderBox>());
    expect((ro! as RenderBox).hasSize, isTrue,
        reason: 'seeded node must be laid out');
    expect(errors, isEmpty, reason: errors.join('\n'));
  });
}
