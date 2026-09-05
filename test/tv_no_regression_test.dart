// Guards against the exact ways this bug came back three times.
//
// Every previous round shipped a green suite and was still dead on the
// device, because the tests exercised a topology or a gate state that the
// real device never had. These assertions pin the *structural* invariants
// that made those escapes possible.
import 'dart:io';

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
    TVFocusScope.onBackKey = null;
  });

  test('SOURCE: TVFocusScope.build has no detection gate', () {
    // Round 3 shipped `if (!PlatformUtils.isTV) return widget.child;` at the
    // top of build(). On a box where detection fails that never mounts the
    // key listener, so the app cannot even observe that it guessed wrong.
    final src =
        File('lib/common/widgets/tv_focus_scope.dart').readAsStringSync();
    final build = src.substring(src.indexOf('Widget build(BuildContext'));
    expect(build.contains('return widget.child'), isFalse,
        reason: 'build() must ALWAYS mount; a detection miss must never make '
            'the key listener disappear');
    expect(build.contains('PlatformUtils.isTV'), isFalse,
        reason: 'build() must not read raw detection');
  });

  test('SOURCE: seeding never consumes a key it failed to satisfy', () {
    // Round 4's livelock: _onKey returned `handled` unconditionally after
    // calling _seedFocus(), so when seeding failed (or landed on a scope
    // node) every press was swallowed and the remote stayed dead forever.
    final src =
        File('lib/common/widgets/tv_focus_scope.dart').readAsStringSync();
    expect(
      RegExp(r'_seedFocus\(\)\s*\?\s*KeyEventResult\.handled').hasMatch(src),
      isTrue,
      reason: 'the press may only be consumed when seeding SUCCEEDED',
    );
  });

  test('SOURCE: main.dart mounts the scope for all mobile, ungated', () {
    final src = File('lib/main.dart').readAsStringSync();
    expect(src.contains('PlatformUtils.isMobile'), isTrue);
    expect(
      RegExp(r'if \(PlatformUtils\.isTV\)[\s\S]{0,80}TVFocusScope')
          .hasMatch(src),
      isFalse,
      reason: 'mounting the focus scope must not depend on TV detection',
    );
  });

  testWidgets('the remote key probe survives a route change', (tester) async {
    // The probe is a HardwareKeyboard handler registered in initState. If it
    // were ever registered per-route, navigating would silently drop it and
    // the remote would go dead again "later" — the same symptom, delayed.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TVFocusScope(child: child!),
        home: Scaffold(
          body: Column(
            children: [
              for (final l in ['a', 'b'])
                InkWell(
                  onTap: () {},
                  child: SizedBox(height: 80, child: Text(l)),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    for (var i = 0; i < 3; i++) {
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: InkWell(
              onTap: () {},
              child: const SizedBox(height: 80, child: Text('deep')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Only NOW press a key — after several navigations.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(PlatformUtils.dpadMode, isTrue,
        reason: 'the global key probe must still be alive after navigation');
  });

  testWidgets('BACK key is routed to the app back handler', (tester) async {
    var backs = 0;
    TVFocusScope.onBackKey = () => backs++;

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TVFocusScope(child: child!),
        home: Scaffold(
          body: InkWell(
            onTap: () {},
            child: const SizedBox(height: 80, child: Text('a')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Not in D-Pad mode yet: back keys must be ignored (phone safety).
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(backs, 0, reason: 'escape on a phone must not pop routes');

    // Enter D-Pad mode with a real arrow, then press BACK.
    // NOTE: `escape` is used here rather than `goBack` only because the test
    // harness has no physical-key mapping for `goBack`; both are covered by
    // DpadNavPolicy.isBackKey in tv_back_key_test.dart.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(backs, 1, reason: 'the remote BACK key must navigate back');
  });

  testWidgets('phones are still untouched: no focus stealing, no highlight',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TVFocusScope(child: child!),
        home: Scaffold(
          body: InkWell(
            onTap: () {},
            child: const SizedBox(height: 80, child: Text('a')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(PlatformUtils.dpadMode, isFalse);
    expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>(),
        reason: 'a touch user must never see focus appear unprompted');
  });
}
