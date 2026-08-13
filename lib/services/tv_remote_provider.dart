import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/login.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/services/logger.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:catcher_2/catcher_2.dart';
import 'package:flutter/foundation.dart';

/// Backs the web remote's login and settings features with the app's real
/// implementations, so the phone drives the same code paths as the TV UI.
///
/// Security notes:
///  * Nothing here is reachable without the pairing code (enforced by
///    TVRemoteServer before dispatch).
///  * The QR flow only exposes bilibili's own login URL plus a status string.
///    Cookies, tokens and auth_code are NEVER serialised to the web client --
///    they are consumed in-process by [LoginHttp] and persisted locally.
///  * Login must additionally be armed on the TV ([loginEnabled]), so a LAN
///    peer cannot silently bind an account.
class TVRemoteProvider {
  TVRemoteProvider._();

  static final TVRemoteProvider instance = TVRemoteProvider._();

  // ---------------------------------------------------------------------
  // QR login (same endpoints as the native login page: getHDcode + codePoll)
  // ---------------------------------------------------------------------

  String? _authCode;
  Timer? _pollTimer;
  String _qrStatus = 'idle';
  String? _qrUrl;
  int _qrLeftSeconds = 0;

  /// Explicit consent gate, toggled from the TV's remote panel.
  bool loginEnabled = false;

  Map<String, dynamic> get loginState => {
        'enabled': loginEnabled,
        'status': _qrStatus,
        // Safe to expose: bilibili's public login URL that the QR encodes.
        'url': _qrUrl,
        'left': _qrLeftSeconds,
        'logged': Accounts.main.isLogin,
        'mid': Accounts.main.isLogin ? Accounts.main.mid : null,
      };

  Future<Map<String, dynamic>> startQrLogin() async {
    if (!loginEnabled) {
      return {...loginState, 'error': 'login not enabled on TV'};
    }
    _cancelPoll();
    final res = await LoginHttp.getHDcode();
    if (res is Success<({String authCode, String url})>) {
      _authCode = res.response.authCode;
      _qrUrl = res.response.url;
      _qrStatus = 'waiting';
      _qrLeftSeconds = 180;
      _startPoll();
      return loginState;
    }
    _qrStatus = 'error';
    return {...loginState, 'error': 'failed to get QR code'};
  }

  void _startPoll() {
    var tick = 0;
    var inFlight = false;
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      tick++;
      _qrLeftSeconds = 180 - tick;
      if (_qrLeftSeconds <= 0) {
        _qrStatus = 'expired';
        _cancelPoll();
        return;
      }
      final code = _authCode;
      if (code == null || inFlight) return;
      inFlight = true;
      try {
        final value = await LoginHttp.codePoll(code);
        if (value['status'] == true) {
          _cancelPoll();
          _qrStatus = 'scanned';
          await _persistAccount(
            value['data'],
            value['data']['cookie_info']['cookies'],
          );
          _qrStatus = 'success';
        } else if (value['code'] == 86038) {
          _qrStatus = 'expired';
          _cancelPoll();
        } else if (value['code'] == 86090) {
          _qrStatus = 'confirming';
        }
      } catch (e) {
        debugPrint('TVRemoteProvider poll error: $e');
      } finally {
        inFlight = false;
      }
    });
  }

  void _cancelPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Mirrors LoginPageController.setAccount without its UI dialogs.
  Future<void> _persistAccount(Map tokenInfo, List cookieInfo) async {
    final wasLoggedIn = Accounts.main.isLogin;
    final account = LoginAccount(
      BiliCookieJar.fromList(cookieInfo),
      tokenInfo['access_token'],
      tokenInfo['refresh_token'],
    );
    await Future.wait([account.onChange(), AnonymousAccount().delete()]);
    for (int i = 0; i < AccountType.values.length; i++) {
      if (Accounts.accountMode[i].mid == account.mid) {
        Accounts.accountMode[i] = account;
      }
    }
    // The native flow pops an account-mode dialog on the TV here. A web user
    // cannot answer that, so when nothing was configured we bind every mode
    // to the new account instead of dead-ending.
    if (!wasLoggedIn) {
      for (final type in AccountType.values) {
        await Accounts.set(type, account);
      }
    }
  }

  Future<Map<String, dynamic>> logout() async {
    final account = Accounts.main;
    if (account is LoginAccount) {
      try {
        await LoginHttp.logout(account);
      } catch (e) {
        debugPrint('TVRemoteProvider logout error: $e');
      }
      await account.delete();
    }
    _qrStatus = 'idle';
    _qrUrl = null;
    _authCode = null;
    return loginState;
  }

  void disposeLogin() => _cancelPoll();

  // ---------------------------------------------------------------------
  // Error logs
  // ---------------------------------------------------------------------

  /// Returns recent Catcher reports with complete stack traces.
  /// Device/application parameter maps are deliberately not exposed.
  Future<Map<String, dynamic>> logsSnapshot(int limit) async {
    final safeLimit = limit.clamp(1, 200);
    final file = await LoggerUtils.getLogsPath();
    final lines = await file.readAsLines();
    final items = <Map<String, dynamic>>[];

    for (final line in lines.reversed) {
      if (items.length >= safeLimit) break;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) continue;
        final report = Report.fromJson(decoded);
        final error = report.error.toString();
        final stackTrace = report.stackTrace?.toString() ?? '';
        items.add({
          'error': error,
          'dateTime': report.dateTime.toIso8601String(),
          'stackTrace': stackTrace,
          'copyText': [
            report.dateTime.toIso8601String(),
            error,
            if (stackTrace.isNotEmpty) stackTrace,
          ].join('\n'),
        });
      } catch (e) {
        items.add({
          'error': 'Parse log failed: $e',
          'dateTime': '',
          'stackTrace': '',
          'copyText': 'Parse log failed: $e\n$line',
        });
      }
    }

    return {'items': items, 'count': items.length, 'total': lines.length};
  }

  // ---------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------

  /// Whitelist of remotely adjustable settings.
  ///
  /// Deliberately narrow: only playback/TV-facing options. Anything
  /// security- or account-related is excluded on purpose, so a paired phone
  /// cannot weaken the device.
  static final List<_RemoteSetting> _settings = [
    _RemoteSetting.boolean(
      key: SettingBoxKey.enableShowDanmaku,
      title: '显示弹幕',
      defaultValue: true,
    ),
    _RemoteSetting.boolean(
      key: SettingBoxKey.autoPlayEnable,
      title: '自动播放',
      defaultValue: true,
    ),
    _RemoteSetting.boolean(
      key: SettingBoxKey.horizontalScreen,
      title: '横屏模式',
      defaultValue: true,
    ),
    _RemoteSetting.boolean(
      key: SettingBoxKey.forceDpadMode,
      title: '电视遥控模式',
      defaultValue: false,
    ),
    _RemoteSetting.options(
      key: SettingBoxKey.defaultVideoQa,
      title: '默认画质',
      defaultValue: VideoQuality.high1080.code,
      options: [
        for (final q in VideoQuality.values) _Option(q.code, q.desc),
      ],
    ),
  ];

  Map<String, dynamic> settingsSnapshot() => {
        'items': [for (final s in _settings) s.toJson()],
      };

  /// Applies one setting. Returns the refreshed snapshot.
  Map<String, dynamic> applySettings(Map<String, dynamic> data) {
    final key = data['key'];
    if (key is String) {
      final match = _settings.where((s) => s.key == key).firstOrNull;
      if (match == null) {
        debugPrint('TVRemoteProvider: "$key" is not remotely adjustable');
      } else {
        match.apply(data['value']);
      }
    }
    return settingsSnapshot();
  }
}

class _Option {
  const _Option(this.value, this.label);
  final Object value;
  final String label;

  Map<String, dynamic> toJson() => {'value': value, 'label': label};
}

class _RemoteSetting {
  _RemoteSetting.boolean({
    required this.key,
    required this.title,
    required bool defaultValue,
  })  : type = 'bool',
        _default = defaultValue,
        options = null;

  _RemoteSetting.options({
    required this.key,
    required this.title,
    required Object defaultValue,
    required this.options,
  })  : type = 'options',
        _default = defaultValue;

  final String key;
  final String title;
  final String type;
  final Object _default;
  final List<_Option>? options;

  Object? get value => GStorage.setting.get(key, defaultValue: _default);

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'type': type,
        'value': value,
        if (options != null) 'options': [for (final o in options!) o.toJson()],
      };

  void apply(Object? raw) {
    if (raw == null) return;
    if (type == 'bool' && raw is bool) {
      GStorage.setting.put(key, raw);
      if (key == SettingBoxKey.forceDpadMode) {
        PlatformUtils.setForceDpad(raw);
      }
      return;
    }
    if (type == 'options') {
      // Only accept values we advertised, never arbitrary input.
      final allowed = options!.map((o) => o.value).toSet();
      if (allowed.contains(raw)) {
        GStorage.setting.put(key, raw);
      }
    }
  }
}
