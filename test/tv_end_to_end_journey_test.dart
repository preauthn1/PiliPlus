// End-to-end rehearsal of the real app shell with a real remote.
//
// Every previous round passed on toy widget trees and failed on the device.
// This drives the structures the app actually uses, in the order a user hits
// them, from the state the user's box is really in (detection FAILED):
//
//   TabBarView main page (siblings mounted+laid out but off screen)
//     -> arrow / OK to open an item
//     -> nested route with a lazily-built ListView
//     -> BACK out again
//
// and asserts on user-visible outcomes (what got activated, where focus is),
// not on internal structure.
import 'package:PiliPlus/common/widgets/tv_focus_scope.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    PlatformUtils.debugForceTV = null;
    PlatformUtils.setAndroidTV(false); // native probe failed, as in the field
    PlatformUtils.setForceDpad(false);
  });
  tearDown(() {
    PlatformUtils.debugForceTV = null;
    PlatformUtils.setForceDpad(false);
    TVFocusScope.onBackKey = null;
  });

  testWidgets('full journey on a box where TV detection fails',
      (tester) async {
    final errors = <String>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString());
    addTearDown(() => FlutterError.onError = prevOnError);

    final opened = <String>[];
    var backPresses = 0;
    TVFocusScope.onBackKey = () {
      backPresses++;
      final nav = Get_navigatorKey.currentState;
      if (nav != null && nav.canPop()) nav.pop();
    };

    Widget tab(String name, int count) => ListView.builder(
          itemCount: count,
          itemBuilder: (context, i) => InkWell(
            onTap: () => opened.add('$name-$i'),
            child: SizedBox(height: 90, child: Text('$name-$i')),
          ),
        );

    final controller = TabController(length: 3, vsync: tester);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: Get_navigatorKey,
        // EXACTLY how main.dart mounts it: above the Navigator.
        builder: (context, child) => TVFocusScope(child: child!),
        home: Scaffold(
          body: TabBarView(
            controller: controller,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              tab('home', 40),
              tab('hot', 40),
              tab('mine', 40),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // --- 1. nothing is focused and the app does not think it is a TV -------
    expect(PlatformUtils.isTV, isFalse);
    expect(PlatformUtils.dpadMode, isFalse);

    // --- 2. user presses DOWN on the remote -------------------------------
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(PlatformUtils.dpadMode, isTrue,
        reason: 'a real D-Pad key must switch the app into remote mode');

    var focused = FocusManager.instance.primaryFocus;
    expect(focused, isNot(isA<FocusScopeNode>()),
        reason: 'the remote must have a real, traversable origin');

    // --- 3. it must be on the VISIBLE tab ---------------------------------
    // Drive several presses; every activation must come from 'home'.
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(opened, isNotEmpty, reason: 'OK must open the focused card');
    expect(opened.every((e) => e.startsWith('home-')), isTrue,
        reason: 'focus escaped to an off-screen tab: $opened');

    // --- 4. push a nested route, navigate it, come back -------------------
    final detailTaps = <String>[];
    Get_navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: ListView.builder(
            itemCount: 200,
            itemBuilder: (context, i) => InkWell(
              onTap: () => detailTaps.add('d$i'),
              child: SizedBox(height: 70, child: Text('d$i')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A fresh route usually starts unfocused. Recover within a couple presses.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()),
        reason: 'the remote must not die after opening a page');

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(detailTaps, isNotEmpty,
        reason: 'OK must work on the newly pushed route too');

    // --- 5. BACK gets the user out ----------------------------------------
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(backPresses, 1);
    expect(find.text('home-0'), findsOneWidget,
        reason: 'BACK must return to the main page');

    // --- 6. and the remote still works after coming back ------------------
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    final before = opened.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(opened.length, greaterThan(before),
        reason: 'the remote must still work after returning from a page');
    expect(opened.every((e) => e.startsWith('home-')), isTrue);

    // --- 7. no crashes anywhere in the journey ----------------------------
    expect(errors, isEmpty,
        reason: 'exceptions during the journey:\n'
            '${errors.take(3).join("\n---\n")}');
  });
}

final Get_navigatorKey = GlobalKey<NavigatorState>();
