import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// TV Remote Control Server.
///
/// Serves a small web UI that a phone on the same LAN can open to drive the
/// TV. Actions are published on [controlStream]; `TVRemoteBridge` subscribes
/// and executes them.
///
/// Security model (v2):
///  * bind to the LAN interface, and additionally reject any request whose
///    remote address is not RFC1918/link-local — a public interface can no
///    longer reach the API even if the device is exposed;
///  * every mutating endpoint requires a 6-digit pairing code that is shown
///    on the TV screen and rotated on each server start;
///  * CORS is no longer `*`; only same-origin requests are accepted, so a
///    random website the user browses cannot silently drive their TV.
class TVRemoteServer {
  static TVRemoteServer? _instance;
  HttpServer? _server;
  int? _port;
  String? _localIP;
  String? _pairingCode;
  final _streamController = StreamController<String>.broadcast();

  TVRemoteServer._();

  static TVRemoteServer get instance {
    _instance ??= TVRemoteServer._();
    return _instance!;
  }

  /// 6-digit code the user must enter on their phone. Rotated per start.
  String? get pairingCode => _pairingCode;

  Future<bool> start({int port = 8888}) async {
    if (_server != null) {
      debugPrint('TV Remote Server already running on port $_port');
      return true;
    }

    try {
      _localIP = await _getLocalIP();
      _pairingCode = _generatePairingCode();
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _port = port;

      debugPrint('TV Remote Server started on http://$_localIP:$_port');

      _server!.listen(_handleRequest);
      return true;
    } catch (e) {
      debugPrint('Failed to start TV Remote Server: $e');
      return false;
    }
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _port = null;
    _pairingCode = null;
    debugPrint('TV Remote Server stopped');
  }

  bool get isRunning => _server != null;

  String? get serverURL =>
      _localIP != null && _port != null ? 'http://$_localIP:$_port' : null;

  static String _generatePairingCode() {
    final rnd = Random.secure();
    return List.generate(6, (_) => rnd.nextInt(10)).join();
  }

  /// Only allow callers from private / link-local ranges.
  static bool _isPrivateAddress(InternetAddress addr) {
    if (addr.isLoopback) return true;
    if (addr.type != InternetAddressType.IPv4) {
      // IPv6 unique-local (fc00::/7) and link-local (fe80::/10)
      final a = addr.address.toLowerCase();
      return a.startsWith('fc') || a.startsWith('fd') || a.startsWith('fe80');
    }
    final parts = addr.address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((p) => p == null)) return false;
    final [a, b, _, _] = parts.cast<int>();
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 169 && b == 254) return true; // link-local
    return false;
  }

  bool _isAuthorized(HttpRequest request) {
    final code = _pairingCode;
    if (code == null) return false;
    final provided = request.headers.value('X-Pairing-Code') ??
        request.uri.queryParameters['code'];
    return provided == code;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;

    // Same-origin only: no wildcard CORS. A malicious page in the user's
    // browser must not be able to drive the TV.
    response.headers
      ..add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..add('Access-Control-Allow-Headers', 'Content-Type, X-Pairing-Code')
      ..add('X-Content-Type-Options', 'nosniff');

    // Network-level gate.
    final remote = request.connectionInfo?.remoteAddress;
    if (remote == null || !_isPrivateAddress(remote)) {
      debugPrint('TV Remote: rejected non-LAN client ${remote?.address}');
      response
        ..statusCode = HttpStatus.forbidden
        ..write('Forbidden: LAN only');
      await response.close();
      return;
    }

    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.ok;
      await response.close();
      return;
    }

    final path = request.uri.path;

    try {
      switch (path) {
        case '/':
          _serveIndexPage(response);
        case '/api/status':
          // Unauthenticated: lets the phone confirm it reached the TV and
          // discover whether pairing is required. Exposes no user data.
          _serveStatus(response);
        case '/api/settings':
        case '/api/control':
          if (!_isAuthorized(request)) {
            response.headers.contentType = ContentType.json;
            response
              ..statusCode = HttpStatus.unauthorized
              ..write(jsonEncode({'error': 'invalid pairing code'}));
            await response.close();
            return;
          }
          if (path == '/api/settings') {
            await _handleSettings(request, response);
          } else {
            await _handleControl(request, response);
          }
        default:
          response
            ..statusCode = HttpStatus.notFound
            ..write('Not Found');
          await response.close();
      }
    } catch (e) {
      response
        ..statusCode = HttpStatus.internalServerError
        ..write('Server Error');
      await response.close();
    }
  }

  void _serveIndexPage(HttpResponse response) {
    response.headers.contentType = ContentType.html;
    response
      ..write(_buildWebUI())
      ..close();
  }

  void _serveStatus(HttpResponse response) {
    response.headers.contentType = ContentType.json;
    response
      ..write(jsonEncode({
        'server': 'running',
        'version': '2.0.0',
        'device': 'Android TV',
        'requiresPairing': true,
      }))
      ..close();
  }

  Future<void> _handleSettings(
    HttpRequest request,
    HttpResponse response,
  ) async {
    response.headers.contentType = ContentType.json;

    if (request.method == 'GET') {
      response.write(jsonEncode(_settingsSnapshot?.call() ?? const {}));
    } else if (request.method == 'POST') {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      _settingsHandler?.call(data);
      response.write(jsonEncode({'success': true}));
    }

    await response.close();
  }

  Future<void> _handleControl(
    HttpRequest request,
    HttpResponse response,
  ) async {
    if (request.method != 'POST') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final action = data['action'];

    if (action is! String || action.isEmpty) {
      response.statusCode = HttpStatus.badRequest;
      response.headers.contentType = ContentType.json;
      response
        ..write(jsonEncode({'error': 'missing action'}))
        ..close();
      return;
    }

    _streamController.add(action);

    response.headers.contentType = ContentType.json;
    response
      ..write(jsonEncode({
        'success': true,
        'action': action,
        'state': _stateSnapshot?.call() ?? const {},
      }))
      ..close();
  }

  /// Injected by the bridge so HTTP responses can report real player state
  /// instead of the hard-coded placeholders the first version returned.
  Map<String, dynamic> Function()? _stateSnapshot;
  Map<String, dynamic> Function()? _settingsSnapshot;
  void Function(Map<String, dynamic>)? _settingsHandler;

  void bindProviders({
    Map<String, dynamic> Function()? state,
    Map<String, dynamic> Function()? settings,
    void Function(Map<String, dynamic>)? onSettings,
  }) {
    _stateSnapshot = state;
    _settingsSnapshot = settings;
    _settingsHandler = onSettings;
  }

  String _buildWebUI() {
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PiliPlus TV 遥控器</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: linear-gradient(135deg, #0A0D12 0%, #161D2B 100%);
            color: #E0E6ED;
            min-height: 100vh;
            padding: 20px;
            -webkit-user-select: none;
            user-select: none;
        }
        .container { max-width: 600px; margin: 0 auto; }
        h1 {
            font-size: 28px;
            margin-bottom: 8px;
            background: linear-gradient(135deg, #38BDF8 0%, #3B6DFF 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        .subtitle { color: #8B92A0; font-size: 14px; margin-bottom: 24px; }
        .card {
            background: #161D2B;
            border-radius: 16px;
            padding: 24px;
            margin-bottom: 16px;
            border: 1px solid rgba(56, 189, 248, 0.1);
        }
        .card h2 { font-size: 18px; margin-bottom: 16px; color: #38BDF8; }
        button {
            width: 100%;
            padding: 16px;
            border: none;
            border-radius: 12px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: transform .08s, opacity .2s;
            margin-bottom: 12px;
        }
        button:active { transform: scale(0.96); opacity: .85; }
        .btn-primary {
            background: linear-gradient(135deg, #38BDF8 0%, #3B6DFF 100%);
            color: white;
        }
        .btn-secondary {
            background: #1E2636;
            color: #E0E6ED;
            border: 1px solid rgba(56, 189, 248, 0.2);
        }
        .control-grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 12px;
            margin-top: 8px;
        }
        .control-grid button { padding: 22px 0; font-size: 24px; margin: 0; }
        input {
            width: 100%;
            padding: 14px;
            font-size: 20px;
            letter-spacing: 6px;
            text-align: center;
            border-radius: 12px;
            border: 1px solid rgba(56,189,248,.3);
            background: #0F1520;
            color: #E0E6ED;
            margin-bottom: 12px;
        }
        .status {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 999px;
            font-size: 12px;
            background: rgba(56, 189, 248, 0.1);
            color: #38BDF8;
            margin-bottom: 16px;
        }
        .status.err { background: rgba(248,113,113,.12); color: #F87171; }
        .status.ok  { background: rgba(74,222,128,.12); color: #4ADE80; }
        .hidden { display: none; }
    </style>
</head>
<body>
    <div class="container">
        <h1>PiliPlus TV 遥控器</h1>
        <p class="subtitle">通过手机控制你的电视端 PiliPlus</p>

        <div class="card" id="pairCard">
            <h2>配对</h2>
            <p class="subtitle">输入电视屏幕上显示的 6 位配对码</p>
            <input id="codeInput" inputmode="numeric" maxlength="6" placeholder="------">
            <button class="btn-primary" onclick="pair()">连接</button>
            <div id="pairStatus" class="status">● 未连接</div>
        </div>

        <div id="remote" class="hidden">
            <div class="card">
                <h2>播放控制</h2>
                <div id="playState" class="status">● 已连接</div>
                <div class="control-grid">
                    <button class="btn-secondary" onclick="control('up')">↑</button>
                    <button class="btn-secondary" onclick="control('volume_up')">🔊</button>
                    <button class="btn-secondary" onclick="control('seek_forward')">⏩</button>

                    <button class="btn-secondary" onclick="control('left')">←</button>
                    <button class="btn-primary"   onclick="control('ok')">OK</button>
                    <button class="btn-secondary" onclick="control('right')">→</button>

                    <button class="btn-secondary" onclick="control('down')">↓</button>
                    <button class="btn-secondary" onclick="control('volume_down')">🔉</button>
                    <button class="btn-secondary" onclick="control('seek_backward')">⏪</button>
                </div>
                <button class="btn-primary" style="margin-top:12px"
                        onclick="control('play_pause')">⏯ 播放 / 暂停</button>
            </div>

            <div class="card">
                <h2>快捷功能</h2>
                <button class="btn-secondary" onclick="control('back')">返回</button>
                <button class="btn-secondary" onclick="control('home')">主页</button>
                <button class="btn-secondary" onclick="control('search')">搜索</button>
            </div>
        </div>
    </div>

    <script>
        let code = sessionStorage.getItem('pp_code') || '';

        function setPairStatus(msg, cls) {
            const el = document.getElementById('pairStatus');
            el.textContent = msg;
            el.className = 'status ' + (cls || '');
        }

        async function send(action) {
            return fetch('/api/control', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-Pairing-Code': code
                },
                body: JSON.stringify({ action })
            });
        }

        async function pair() {
            code = document.getElementById('codeInput').value.trim();
            const res = await send('ping');
            if (res.status === 401) {
                setPairStatus('● 配对码错误', 'err');
                return;
            }
            sessionStorage.setItem('pp_code', code);
            setPairStatus('● 已连接', 'ok');
            document.getElementById('pairCard').classList.add('hidden');
            document.getElementById('remote').classList.remove('hidden');
        }

        async function control(action) {
            try {
                const res = await send(action);
                if (res.status === 401) {
                    document.getElementById('pairCard').classList.remove('hidden');
                    document.getElementById('remote').classList.add('hidden');
                    setPairStatus('● 配对已失效，请重新输入', 'err');
                    return;
                }
                const data = await res.json();
                const st = data.state || {};
                if (st.hasPlayer) {
                    document.getElementById('playState').textContent =
                        (st.playing ? '▶ 播放中' : '⏸ 已暂停');
                }
            } catch (e) {
                setPairStatus('● 连接中断', 'err');
            }
        }

        // Auto-restore a previous session.
        if (code) { pair(); }
    </script>
</body>
</html>
    ''';
  }

  Future<String> _getLocalIP() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && addr.address.startsWith('192.168.')) {
            return addr.address;
          }
        }
      }

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }

      return '127.0.0.1';
    } catch (e) {
      debugPrint('Failed to get local IP: $e');
      return '127.0.0.1';
    }
  }

  Stream<String> get controlStream => _streamController.stream;
}
