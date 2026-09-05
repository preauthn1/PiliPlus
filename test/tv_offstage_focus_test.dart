// Focus must never land on a widget the user cannot see.
//
// The main page is a TabBarView/PageView with NeverScrollableScrollPhysics,
// so sibling tabs stay mounted and laid out. A focus node inside an
// off-screen tab passes every "is it laid out" screen, so seeding or
// traversal can hand focus to something invisible. The user then presses OK
// and a card on a completely different tab opens — or, far more often, the
// highlight is simply nowhere on screen and it reads as "遥控器没反应".
//
// Same for `Offstage`, which Flutter uses for inactive routes and for
// keep-alive list content.
import 'package:PiliPlus/common/widgets/tv_focus_scope.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    PlatformUtils.debugForceTV = null;
    PlatformUtils.setAndroidTV(false);
    PlatformUtils.setForceDpad(false);
  });
  tearDown(() {
    PlatformUtils.debugForceTV = null;
    PlatformUtils.setForceDpad(false);
  });

  testWidgets('seeding skips widgets hidden behind Offstage', (tester) async {
    final tapped = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TVFocusScope(child: child!),
        home: Scaffold(
          body: Column(
            children: [
              // Hidden tab content, mounted and laid out but invisible.
              Offstage(
                offstage: true,
                child: Column(
                  children: [
                    for (final l in ['hidden1', 'hidden2'])
                      InkWell(
                        onTap: () => tapped.add(l),
                        child: SizedBox(height: 60, child: Text(l)),
                      ),
                  ],
                ),
              ),
              // The visible tab.
              for (final l in ['visible1', 'visible2'])
                InkWell(
                  onTap: () => tapped.add(l),
                  child: SizedBox(height: 60, child: Text(l)),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(tapped, isNotEmpty, reason: 'OK must activate something');
    expect(
      tapped.every((e) => e.startsWith('visible')),
      isTrue,
      reason: 'focus landed on an OFF-SCREEN widget ($tapped); the user sees '
          'no highlight and OK opens the wrong thing',
    );
  });

  testWidgets('seeding skips a zero-size (collapsed) widget', (tester) async {
    final tapped = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TVFocusScope(child: child!),
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                height: 0,
                width: 0,
                child: InkWell(
                  onTap: () => tapped.add('collapsed'),
                  child: const SizedBox.shrink(),
                ),
              ),
              InkWell(
                onTap: () => tapped.add('real'),
                child: const SizedBox(height: 60, child: Text('real')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(tapped, ['real'],
        reason: 'a zero-size node gives the user no visible focus target');
  });
}
