import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';

/// Wraps a card that already contains its own focusable [InkWell] and paints
/// a strong focus treatment when anything inside it holds focus.
///
/// This is a *decoration only* widget: it deliberately does not create a
/// focusable node of its own (`canRequestFocus: false`), so it never competes
/// with the inner InkWell for D-Pad traversal or creates duplicate stops.
///
/// Replaces the previous `TVCard`, which required rewriting every call site
/// and was therefore never actually adopted anywhere in the app.
class TVFocusHighlight extends StatefulWidget {
  const TVFocusHighlight({
    super.key,
    required this.child,
    this.borderRadius = 12,
    this.scale = 1.04,
  });

  final Widget child;
  final double borderRadius;
  final double scale;

  @override
  State<TVFocusHighlight> createState() => _TVFocusHighlightState();
}

class _TVFocusHighlightState extends State<TVFocusHighlight> {
  bool _focused = false;

  void _onFocusChange(bool value) {
    if (_focused != value && mounted) {
      setState(() => _focused = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Zero overhead on phones/tablets/desktop.
    if (!PlatformUtils.isTV) {
      return widget.child;
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onFocusChange,
      child: AnimatedScale(
        scale: _focused ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: _focused ? colorScheme.primary : Colors.transparent,
              width: 3,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: colorScheme.primary.withValues(alpha: 0.35),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
