import 'package:PiliPlus/utils/dpad_nav_policy.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderOffstage;
import 'package:flutter/services.dart';

/// Root-level focus plumbing for TV / D-Pad navigation.
///
/// This fixes the core reason the remote appeared dead: on a fresh start no
/// widget ever held focus, so [FocusManager.primaryFocus] was null and the
/// directional keys had no origin node to traverse from, while OK/Select had
/// no target to activate.
///
/// Flutter's default [ReadingOrderTraversalPolicy] already mixes in
/// [DirectionalFocusTraversalPolicyMixin], so arrow-key traversal works once
/// *something* is focused. We therefore only need to seed and maintain focus,
/// plus map the extra keycodes some TV remotes emit.
class TVFocusScope extends StatefulWidget {
  const TVFocusScope({super.key, required this.child});

  final Widget child;

  /// Invoked when the remote's BACK key arrives as a plain key event.
  ///
  /// Wired from main.dart to the app's existing back handler, so the remote
  /// and the system back button share one code path and cannot drift.
  static VoidCallback? onBackKey;

  /// Test-only handle on the crash-safe focus request callback.
  @visibleForTesting
  static void debugSafeRequestFocus(
    FocusNode node, {
    ScrollPositionAlignmentPolicy? alignmentPolicy,
    double? alignment,
    Duration? duration,
    Curve? curve,
  }) =>
      _TVFocusScopeState._safeRequestFocus(
        node,
        alignmentPolicy: alignmentPolicy,
        alignment: alignment,
        duration: duration,
        curve: curve,
      );

  /// Test-only handle on the seed-candidate screen.
  @visibleForTesting
  static bool debugIsSeedable(FocusNode node) =>
      _TVFocusScopeState._isFocusable(node);

  @override
  State<TVFocusScope> createState() => _TVFocusScopeState();
}

class _TVFocusScopeState extends State<TVFocusScope> {
  final FocusNode _rootNode = FocusNode(
    debugLabel: 'TVRootFocus',
    skipTraversal: true,
  );

  int _seedAttempts = 0;

  @override
  void initState() {
    super.initState();
    // Only pre-seed when we already believe this is a TV. Otherwise we wait
    // for a real D-Pad key so we never steal focus on a phone.
    if (PlatformUtils.dpadMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _seedFocus());
    }
    PlatformUtils.dpadModeNotifier.addListener(_onDpadModeChanged);
    // Observe keys BEFORE the focus/shortcut system consumes them.
    //
    // Focus.onKeyEvent only fires along the focused node's ancestor chain,
    // and arrow keys are consumed by Shortcuts/DirectionalFocusAction before
    // they ever bubble up here. That meant D-Pad presses were invisible to
    // us and remote mode could never auto-enable. A raw global handler sees
    // every key regardless of focus state.
    HardwareKeyboard.instance.addHandler(_globalKeyProbe);
  }

  /// Passive probe: never consumes a key, only records evidence that a
  /// physical D-Pad is in use.
  bool _globalKeyProbe(KeyEvent event) {
    if (event is KeyDownEvent &&
        _isDpadEvidence(event.logicalKey) &&
        !PlatformUtils.dpadMode) {
      PlatformUtils.reportDpadKey();
    }
    return false; // always let the event continue
  }

  void _onDpadModeChanged() {
    if (!mounted) return;
    setState(() {});
    if (PlatformUtils.dpadMode) {
      // Orientation is re-applied by PlatformUtils.onDpadModeEnabled (wired
      // in main.dart) — keeping that out of this file avoids dragging the
      // player/storage dependency chain into the root focus widget.
      _seedAttempts = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _seedFocus());
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_globalKeyProbe);
    PlatformUtils.dpadModeNotifier.removeListener(_onDpadModeChanged);
    _rootNode.dispose();
    super.dispose();
  }

  bool get _focusIsEmpty {
    final current = FocusManager.instance.primaryFocus;
    // A scope with no focused descendant still reports itself as primaryFocus
    // but cannot be traversed from, so treat that as empty too.
    return current == null ||
        current is FocusScopeNode ||
        current.context == null;
  }

  /// Whether a node is safe to focus.
  ///
  /// Two independent screens, both learned the hard way:
  ///
  ///  * **Never a [FocusScopeNode]** — see above.
  ///  * **Must be laid out** — focusing an attached-but-unlaid-out node makes
  ///    Flutter's default traversal callback call `Scrollable.ensureVisible`,
  ///    which reads `RenderBox.size` and throws
  ///    `Bad state: RenderBox was not laid out`. Lazily-built lists routinely
  ///    contain such nodes.
  ///  * **Must actually be visible** — the main page is a TabBarView/PageView,
  ///    so sibling tabs stay mounted *and laid out* while off screen. Such a
  ///    node passes every size check, so seeding could hand focus to something
  ///    the user cannot see: no highlight appears anywhere and OK opens an
  ///    item from a different tab. `Offstage` and zero-size nodes are the same
  ///    class of problem.
  static bool _isFocusable(FocusNode node) {
    if (node is FocusScopeNode) return false;
    if (!node.canRequestFocus || node.skipTraversal) return false;
    final context = node.context;
    if (context == null || !context.mounted) return false;
    final ro = context.findRenderObject();
    if (ro is! RenderBox) return false;
    if (!ro.attached || !ro.hasSize) return false;
    // Zero-size widgets give the user nothing to look at.
    if (ro.size.isEmpty) return false;
    // Hidden by Offstage / an inactive TabBarView page.
    if (!_isVisible(ro)) return false;
    return true;
  }

  /// Whether [box] is currently painted on screen.
  ///
  /// Walks up the render tree looking for anything that suppresses painting.
  /// `Offstage` (used for inactive routes and keep-alive content) still lays
  /// its subtree out, so a size check alone does not catch it.
  static bool _isVisible(RenderBox box) {
    RenderObject? node = box;
    var depth = 0;
    while (node != null && depth++ < 200) {
      if (node is RenderOffstage && node.offstage) return false;
      final parent = node.parent;
      if (parent == null) break;
      // paintsChild() is false for the non-visible children of Offstage,
      // Visibility, IndexedStack and inactive TabBarView pages.
      if (!parent.paintsChild(node)) return false;
      node = parent;
    }
    return true;
  }

  /// The scope that owns the currently visible route.
  ///
  /// Mounted above the Navigator, `_rootNode.nearestScope` is the *app* scope,
  /// whose descendants also include every route still mounted underneath the
  /// top one. Seeding from there could focus an invisible widget on a covered
  /// page. Walking down the `focusedChild` chain lands on the innermost active
  /// scope, which is the current route.
  FocusScopeNode? _activeScope() {
    FocusScopeNode? scope = _rootNode.nearestScope;
    if (scope == null) return null;
    // Bounded: guards against a pathological cycle in the focus tree.
    for (var depth = 0; depth < 32; depth++) {
      final child = scope!.focusedChild;
      if (child is FocusScopeNode && child != scope) {
        scope = child;
      } else {
        break;
      }
    }
    return scope;
  }

  /// Give the D-Pad an origin. Without this the first key press is swallowed.
  ///
  /// Returns whether a real, traversable node now holds focus. Callers must
  /// only consume a key press when this returned true — consuming on failure
  /// is exactly how the remote went permanently dead before.
  bool _seedFocus() {
    if (!mounted) return false;
    if (!_focusIsEmpty) {
      _seedAttempts = 0;
      return true;
    }

    final scope = _activeScope();
    if (scope != null) {
      // Prefer whatever this scope last had focused (route restore). Note
      // _isFocusable rejects scope nodes, so a remembered *scope* correctly
      // falls through to the descendant search below.
      final remembered = scope.focusedChild;
      if (remembered != null && _isFocusable(remembered)) {
        remembered.requestFocus();
        _seedAttempts = 0;
        return true;
      }
      final candidate =
          scope.traversalDescendants.where(_isFocusable).firstOrNull;
      if (candidate != null) {
        candidate.requestFocus();
        _seedAttempts = 0;
        return true;
      }
    }

    // Tree still building (async page content). Retry for a bounded window
    // rather than spinning a post-frame callback forever.
    if (_seedAttempts++ < 40) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _seedFocus());
    }
    return false;
  }

  /// Keys that prove a physical remote / D-Pad is driving the app.
  ///
  /// Deliberately excludes `enter`, which a Bluetooth keyboard on a phone
  /// would also send, to avoid switching a phone into TV styling.
  static bool _isDpadEvidence(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.gameButtonA;

  static bool _isNavigationKey(LogicalKeyboardKey key) =>
      _isDpadEvidence(key) || key == LogicalKeyboardKey.enter;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    // GROUND TRUTH: a real D-Pad key just arrived, so this *is* a remote,
    // whatever the device claimed during detection. Device probing fails on
    // many CN TV boxes (UI mode NORMAL, no FEATURE_LEANBACK, touchscreen
    // still advertised), which previously left every TV feature disabled and
    // the remote apparently dead.
    if (_isDpadEvidence(key) && !PlatformUtils.dpadMode) {
      PlatformUtils.reportDpadKey();
    }

    // BACK on the remote. Most boxes send a system back event (PopScope
    // handles those), but some deliver a plain key event that nothing on
    // mobile listened for — so the user could enter a page and never leave.
    if (DpadNavPolicy.isBackKey(key, dpadMode: PlatformUtils.dpadMode)) {
      final handler = TVFocusScope.onBackKey;
      if (handler != null) {
        handler();
        return KeyEventResult.handled;
      }
    }

    // Nothing focused: re-seed so the *next* press has an origin to move from.
    // This is what turns a "dead" remote into a working one after any route
    // change that leaves the tree without focus.
    //
    // Only consume the press when seeding actually SUCCEEDED. Consuming
    // unconditionally is how the remote previously went permanently dead: if
    // the seed target was rejected (or was a scope node, which never counts as
    // focus), every subsequent press was swallowed here and Flutter's own
    // traversal never got a chance to run.
    if (_focusIsEmpty && _isNavigationKey(key)) {
      return _seedFocus() ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    // Gamepad-style buttons some Android TV remotes emit are not in Flutter's
    // default WidgetsApp activation shortcut map.
    if (key == LogicalKeyboardKey.gameButtonA) {
      final primary = FocusManager.instance.primaryFocus;
      if (primary != null && _isFocusable(primary)) {
        Actions.maybeInvoke(primary.context!, const ActivateIntent());
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  /// Focus-request callback that will not crash on unlaid-out nodes.
  ///
  /// Flutter's [FocusTraversalPolicy.defaultTraversalRequestFocusCallback]
  /// unconditionally does `node.context!` and `Scrollable.ensureVisible(...)`.
  /// When D-Pad traversal lands on a node inside a lazily-built list that is
  /// attached but not yet laid out, that throws:
  ///   * `Null check operator used on a null value`
  ///   * `Bad state: RenderBox was not laid out: RenderSemanticsAnnotations#...`
  /// Both were observed on device as a rapid burst while navigating.
  static void _safeRequestFocus(
    FocusNode node, {
    ScrollPositionAlignmentPolicy? alignmentPolicy,
    double? alignment,
    Duration? duration,
    Curve? curve,
  }) {
    node.requestFocus();
    // Only scroll it into view once we know it is actually laid out.
    if (!_isFocusable(node)) return;
    Scrollable.ensureVisible(
      node.context!,
      alignment: alignment ?? 1,
      alignmentPolicy: alignmentPolicy ?? ScrollPositionAlignmentPolicy.explicit,
      duration: duration ?? Duration.zero,
      curve: curve ?? Curves.ease,
    );
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: we must ALWAYS install the key listener, even when we do not
    // (yet) believe this is a TV. Previously this returned `widget.child`
    // whenever detection said "not a TV", so on any box where detection
    // failed the listener never existed, D-Pad keys were never observed, and
    // the remote was permanently dead with no way to recover.
    //
    // The listener is passive on phones: it only reacts to D-Pad keycodes,
    // which a touch device never sends.
    return FocusTraversalGroup(
      // Same ordering as Flutter's default (which already provides
      // directional traversal), but with a crash-safe focus request.
      policy: ReadingOrderTraversalPolicy(
        requestFocusCallback: _safeRequestFocus,
      ),
      child: Focus(
        focusNode: _rootNode,
        onKeyEvent: _onKey,
        child: widget.child,
      ),
    );
  }
}
