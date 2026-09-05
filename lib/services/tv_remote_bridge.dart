import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/tv_remote_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// Executes the actions emitted by [TVRemoteServer].
///
/// Previously [TVRemoteServer] pushed every action into a broadcast stream
/// that had **no subscriber**, so the web UI got `{"success": true}` back
/// while nothing at all happened on the TV. This class is that missing
/// subscriber, and is what makes the web remote buttons actually work.
///
/// Directional/OK actions are injected as real key events so they reuse the
/// exact same focus-traversal path as the physical remote, instead of
/// duplicating navigation logic.
class TVRemoteBridge {
  TVRemoteBridge._();

  static final TVRemoteBridge instance = TVRemoteBridge._();

  StreamSubscription<String>? _sub;

  void attach() {
    _sub ??= TVRemoteServer.instance.controlStream.listen(
      _handle,
      onError: (Object e) => debugPrint('TVRemoteBridge error: $e'),
    );
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
  }

  PlPlayerController? get _player => PlPlayerController.instance;

  Future<void> _handle(String action) async {
    try {
      switch (action) {
        // ---- playback ----
        case 'play_pause':
          await _togglePlay();
        case 'play':
          await PlPlayerController.playIfExists();
        case 'pause':
          await PlPlayerController.pauseIfExists();
        case 'seek_forward':
          await _seekBy(const Duration(seconds: 10));
        case 'seek_backward':
          await _seekBy(const Duration(seconds: -10));
        case 'volume_up':
          await _bumpVolume(0.1);
        case 'volume_down':
          await _bumpVolume(-0.1);
        case 'mute':
          await PlPlayerController.setVolumeIfExists(0);

        // ---- navigation: replay as real key events ----
        case 'up':
          _sendKey(LogicalKeyboardKey.arrowUp);
        case 'down':
          _sendKey(LogicalKeyboardKey.arrowDown);
        case 'left':
          _sendKey(LogicalKeyboardKey.arrowLeft);
        case 'right':
          _sendKey(LogicalKeyboardKey.arrowRight);
        case 'ok':
        case 'select':
          _activateFocused();

        // ---- app level ----
        case 'back':
          _goBack();
        case 'home':
          _goHome();
        case 'search':
          Get.toNamed('/search');

        default:
          debugPrint('TVRemoteBridge: unknown action "$action"');
      }
    } catch (e, s) {
      debugPrint('TVRemoteBridge failed on "$action": $e\n$s');
    }
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null) return;
    if (player.playerStatus.isPlaying) {
      await PlPlayerController.pauseIfExists();
    } else {
      await PlPlayerController.playIfExists();
    }
  }

  Future<void> _seekBy(Duration delta) async {
    final player = _player;
    if (player == null) return;
    final target = Duration(seconds: player.position.value) + delta;
    final max = Duration(seconds: player.duration.value);
    await PlPlayerController.seekToIfExists(
      target < Duration.zero
          ? Duration.zero
          : (max > Duration.zero && target > max ? max : target),
    );
  }

  Future<void> _bumpVolume(double delta) async {
    final current = PlPlayerController.getVolumeIfExists();
    if (current == null) return;
    await PlPlayerController.setVolumeIfExists(
      (current + delta).clamp(0.0, 1.0),
    );
  }

  /// Drive focus traversal exactly like the hardware D-Pad would.
  void _sendKey(LogicalKeyboardKey key) {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return;
    final direction = switch (key) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    if (direction == null) return;
    Actions.maybeInvoke(ctx, DirectionalFocusIntent(direction));
  }

  void _activateFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return;
    Actions.maybeInvoke(ctx, const ActivateIntent());
  }

  void _goBack() {
    if (Get.key.currentState?.canPop() ?? false) {
      Get.back();
    }
  }

  void _goHome() {
    Get.until((route) => route.isFirst);
  }

  /// Snapshot used by the web UI to render current playback state.
  Map<String, dynamic> currentState() {
    final player = _player;
    if (player == null) {
      return {'playing': false, 'hasPlayer': false};
    }
    return {
      'hasPlayer': true,
      'playing': player.playerStatus.isPlaying,
      'position': player.position.value,
      'duration': player.duration.value,
      'volume': player.volume.value,
    };
  }
}
