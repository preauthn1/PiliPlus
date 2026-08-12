import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';
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
    if (PlatformUtils.isTV) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _seedFocus());
    }
  }

  @override
  void dispose() {
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
  /// Focusing a node that is attached but **not yet laid out** makes
  /// Flutter's default traversal callback call `Scrollable.ensureVisible`,
  /// which reads `RenderBox.size` and throws
  /// `Bad state: RenderBox was not laid out`. Lazily-built lists routinely
  /// contain such nodes, so every candidate must be screened.
  static bool _isFocusable(FocusNode node) {
    if (!node.canRequestFocus || node.skipTraversal) return false;
    final context = node.context;
    if (context == null || !context.mounted) return false;
    final ro = context.findRenderObject();
    if (ro is! RenderBox) return false;
    return ro.attached && ro.hasSize;
  }

  /// Give the D-Pad an origin. Without this the first key press is swallowed.
  void _seedFocus() {
    if (!mounted || !_focusIsEmpty) {
      _seedAttempts = 0;
      return;
    }

    final scope = _rootNode.nearestScope;
    if (scope != null) {
      // Prefer whatever this scope last had focused (route restore).
      final remembered = scope.focusedChild;
      if (remembered != null && _isFocusable(remembered)) {
        remembered.requestFocus();
        _seedAttempts = 0;
        return;
      }
      final candidate =
          scope.traversalDescendants.where(_isFocusable).firstOrNull;
      if (candidate != null) {
        candidate.requestFocus();
        _seedAttempts = 0;
        return;
      }
    }

    // Tree still building (async page content). Retry for a bounded window
    // rather than spinning a post-frame callback forever.
    if (_seedAttempts++ < 40) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _seedFocus());
    }
  }

  static bool _isNavigationKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.gameButtonA;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    // Nothing focused: re-seed and consume this press so the *next* one moves.
    // This is what turns a "dead" remote into a working one after any route
    // change that leaves the tree without focus.
    if (_focusIsEmpty && _isNavigationKey(key)) {
      _seedFocus();
      return KeyEventResult.handled;
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
    if (!PlatformUtils.isTV) {
      return widget.child;
    }
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
