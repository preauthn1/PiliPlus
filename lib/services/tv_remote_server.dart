import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:qr/qr.dart';

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
      // Bind to the LAN address itself rather than anyIPv4 so the socket is
      // not even listening on other interfaces (cellular/VPN/tun). Falls back
      // to anyIPv4 only if no LAN address was found, where the per-request
      // check is still enforced.
      final bindTarget = (strictLan && _localIP != null && _localIP != '127.0.0.1')
          ? InternetAddress(_localIP!)
          : InternetAddress.anyIPv4;
      _server = await HttpServer.bind(bindTarget, port);
      _port = port;

      debugPrint(
        'TV Remote Server listening on ${bindTarget.address}:$port '
        '(url http://$_localIP:$_port)',
      );

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

  /// Only allow callers from the local network.
  ///
  /// [strictLan] (default) restricts to the classic home-LAN ranges the user
  /// asked for — 192.168.x.x plus loopback — so the panel cannot be reached
  /// from a carrier-grade / VPN / hotspot range even if the device is
  /// multi-homed. When false, all RFC1918 + link-local ranges are allowed.
  static bool _isPrivateAddress(InternetAddress addr, {bool strictLan = true}) {
    if (addr.isLoopback) return true;
    if (addr.type != InternetAddressType.IPv4) {
      // IPv6 unique-local (fc00::/7) and link-local (fe80::/10)
      final a = addr.address.toLowerCase();
      if (strictLan) return false;
      return a.startsWith('fc') || a.startsWith('fd') || a.startsWith('fe80');
    }
    final parts = addr.address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((p) => p == null)) return false;
    final [a, b, _, _] = parts.cast<int>();
    if (strictLan) {
      // Home LAN only, as requested: 192.168.0.0/16.
      return a == 192 && b == 168;
    }
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 169 && b == 254) return true; // link-local
    return false;
  }

  /// Whether to restrict callers to 192.168.x.x. Exposed for tests and for
  /// users on 10.x / 172.16.x networks who need the wider range.
  bool strictLan = true;

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
    if (remote == null || !_isPrivateAddress(remote, strictLan: strictLan)) {
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
        case '/api/login/qr.svg':
          if (!_isAuthorized(request)) {
            response
              ..statusCode = HttpStatus.unauthorized
              ..write('unauthorized');
            await response.close();
            return;
          }
          _serveLoginQr(response);
        case '/api/settings':
        case '/api/control':
        case '/api/login':
        case '/api/login/start':
        case '/api/logout':
          if (!_isAuthorized(request)) {
            response.headers.contentType = ContentType.json;
            response
              ..statusCode = HttpStatus.unauthorized
              ..write(jsonEncode({'error': 'invalid pairing code'}));
            await response.close();
            return;
          }
          switch (path) {
            case '/api/settings':
              await _handleSettings(request, response);
            case '/api/control':
              await _handleControl(request, response);
            case '/api/login':
              await _handleLoginState(response);
            case '/api/login/start':
              await _handleLoginStart(response);
            case '/api/logout':
              await _handleLogout(response);
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
      final updated = _settingsHandler?.call(data);
      response.write(jsonEncode(updated ?? {'success': true}));
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

  /// Renders the current login URL as an SVG QR code.
  ///
  /// Generated on-device so the phone never needs internet access or a
  /// third-party QR service (which would leak the login URL).
  void _serveLoginQr(HttpResponse response) {
    final url = _loginState?.call()['url'] as String?;
    if (url == null || url.isEmpty) {
      response
        ..statusCode = HttpStatus.notFound
        ..write('no active login')
        ..close();
      return;
    }

    final qr = QrCode.fromData(
      data: url,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final image = QrImage(qr);
    final n = image.moduleCount;
    const cell = 8;
    final size = n * cell;

    final buf = StringBuffer()
      ..write(
        '<svg xmlns="http://www.w3.org/2000/svg" width="$size" '
        'height="$size" viewBox="0 0 $size $size" shape-rendering="crispEdges">'
        '<rect width="$size" height="$size" fill="#ffffff"/>',
      );
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (image.isDark(y, x)) {
          buf.write(
            '<rect x="${x * cell}" y="${y * cell}" '
            'width="$cell" height="$cell" fill="#000000"/>',
          );
        }
      }
    }
    buf.write('</svg>');

    response.headers
      ..contentType = ContentType('image', 'svg+xml', charset: 'utf-8')
      ..add('Cache-Control', 'no-store');
    response
      ..write(buf.toString())
      ..close();
  }

  Future<void> _handleLoginState(HttpResponse response) async {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(_loginState?.call() ?? const {}));
    await response.close();
  }

  Future<void> _handleLoginStart(HttpResponse response) async {
    response.headers.contentType = ContentType.json;
    final start = _loginStart;
    if (start == null) {
      response.write(jsonEncode({'error': 'login unavailable'}));
    } else {
      response.write(jsonEncode(await start()));
    }
    await response.close();
  }

  Future<void> _handleLogout(HttpResponse response) async {
    response.headers.contentType = ContentType.json;
    final logout = _logout;
    if (logout == null) {
      response.write(jsonEncode({'error': 'logout unavailable'}));
    } else {
      response.write(jsonEncode(await logout()));
    }
    await response.close();
  }

  /// Injected by the bridge so HTTP responses can report real player state
  /// instead of the hard-coded placeholders the first version returned.
  Map<String, dynamic> Function()? _stateSnapshot;
  Map<String, dynamic> Function()? _settingsSnapshot;
  Map<String, dynamic> Function(Map<String, dynamic>)? _settingsHandler;
  Map<String, dynamic> Function()? _loginState;
  Future<Map<String, dynamic>> Function()? _loginStart;
  Future<Map<String, dynamic>> Function()? _logout;

  void bindProviders({
    Map<String, dynamic> Function()? state,
    Map<String, dynamic> Function()? settings,
    Map<String, dynamic> Function(Map<String, dynamic>)? onSettings,
    Map<String, dynamic> Function()? loginState,
    Future<Map<String, dynamic>> Function()? loginStart,
    Future<Map<String, dynamic>> Function()? logout,
  }) {
    _stateSnapshot = state;
    _settingsSnapshot = settings;
    _settingsHandler = onSettings;
    _loginState = loginState;
    _loginStart = loginStart;
    _logout = logout;
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
        .setting-row {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 16px;
            padding: 12px 0;
            border-bottom: 1px solid rgba(255,255,255,.06);
        }
        .setting-row:last-child { border-bottom: none; }
        select {
            padding: 10px 12px;
            border-radius: 10px;
            background: #1E2636;
            color: #E0E6ED;
            border: 1px solid rgba(56,189,248,.25);
            font-size: 15px;
        }
        #qrBox img {
            display: block;
            margin: 0 auto;
            border-radius: 8px;
            background: #fff;
        }
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

            <div class="card">
                <h2>账号</h2>
                <div id="loginStatus" class="status">● 未登录</div>
                <div id="loginDisabled" class="hidden">
                    <p class="subtitle">
                        出于安全考虑，需先在电视上的「手机遥控」页面点击
                        <b>允许网页登录</b>，才能从手机扫码登录。
                    </p>
                </div>
                <div id="loginActions">
                    <button class="btn-primary" onclick="startLogin()">获取登录二维码</button>
                </div>
                <div id="qrBox" class="qr-container hidden">
                    <img id="qrImg" alt="登录二维码" width="220" height="220">
                    <p id="qrHint">请用 B 站 App 扫码</p>
                </div>
                <button id="logoutBtn" class="btn-secondary hidden"
                        onclick="doLogout()">退出登录</button>
            </div>

            <div class="card">
                <h2>设置</h2>
                <div id="settingsBox"><p class="subtitle">加载中…</p></div>
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
            refreshLogin();
            loadSettings();
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

        // ---------- login ----------
        let loginTimer = null;

        function api(path, opts) {
            opts = opts || {};
            opts.headers = Object.assign({}, opts.headers, {
                'X-Pairing-Code': code
            });
            return fetch(path, opts);
        }

        function renderLogin(st) {
            const statusEl = document.getElementById('loginStatus');
            const disabled = document.getElementById('loginDisabled');
            const actions = document.getElementById('loginActions');
            const logoutBtn = document.getElementById('logoutBtn');
            const qrBox = document.getElementById('qrBox');

            if (st.logged) {
                statusEl.textContent = '● 已登录 (mid ' + st.mid + ')';
                statusEl.className = 'status ok';
                actions.classList.add('hidden');
                qrBox.classList.add('hidden');
                disabled.classList.add('hidden');
                logoutBtn.classList.remove('hidden');
                if (loginTimer) { clearInterval(loginTimer); loginTimer = null; }
                return;
            }

            logoutBtn.classList.add('hidden');
            if (!st.enabled) {
                statusEl.textContent = '● 电视未允许网页登录';
                statusEl.className = 'status err';
                disabled.classList.remove('hidden');
                actions.classList.add('hidden');
                return;
            }
            disabled.classList.add('hidden');
            actions.classList.remove('hidden');

            const map = {
                idle: ['● 未登录', ''],
                waiting: ['● 等待扫码', ''],
                confirming: ['● 已扫码，请在手机上确认', ''],
                expired: ['● 二维码已过期，请重新获取', 'err'],
                error: ['● 获取二维码失败', 'err'],
                success: ['● 登录成功', 'ok']
            };
            const m = map[st.status] || ['● ' + st.status, ''];
            statusEl.textContent = m[0];
            statusEl.className = 'status ' + m[1];

            if (st.status === 'waiting' || st.status === 'confirming') {
                document.getElementById('qrHint').textContent =
                    '请用 B 站 App 扫码（剩余 ' + st.left + ' 秒）';
            }
        }

        async function refreshLogin() {
            try {
                const res = await api('/api/login');
                if (res.status === 401) return;
                renderLogin(await res.json());
            } catch (e) {}
        }

        async function startLogin() {
            const res = await api('/api/login/start');
            const st = await res.json();
            if (st.error) {
                renderLogin(st);
                return;
            }
            // Cache-bust so each new session fetches a fresh QR.
            document.getElementById('qrImg').src =
                '/api/login/qr.svg?code=' + encodeURIComponent(code) +
                '&t=' + Date.now();
            document.getElementById('qrBox').classList.remove('hidden');
            renderLogin(st);
            if (loginTimer) clearInterval(loginTimer);
            loginTimer = setInterval(refreshLogin, 2000);
        }

        async function doLogout() {
            const res = await api('/api/logout');
            renderLogin(await res.json());
        }

        // ---------- settings ----------
        function renderSettings(data) {
            const box = document.getElementById('settingsBox');
            const items = (data && data.items) || [];
            if (!items.length) {
                box.innerHTML = '<p class="subtitle">无可调整项</p>';
                return;
            }
            box.innerHTML = '';
            items.forEach(function (it) {
                const row = document.createElement('div');
                row.className = 'setting-row';
                const label = document.createElement('span');
                label.textContent = it.title;
                row.appendChild(label);

                if (it.type === 'bool') {
                    const btn = document.createElement('button');
                    btn.className = it.value ? 'btn-primary' : 'btn-secondary';
                    btn.style.width = 'auto';
                    btn.style.margin = '0';
                    btn.style.padding = '8px 18px';
                    btn.textContent = it.value ? '开' : '关';
                    btn.onclick = function () { setSetting(it.key, !it.value); };
                    row.appendChild(btn);
                } else if (it.type === 'options') {
                    const sel = document.createElement('select');
                    (it.options || []).forEach(function (o) {
                        const op = document.createElement('option');
                        op.value = o.value;
                        op.textContent = o.label;
                        if (o.value === it.value) op.selected = true;
                        sel.appendChild(op);
                    });
                    sel.onchange = function () {
                        setSetting(it.key, parseInt(sel.value, 10));
                    };
                    row.appendChild(sel);
                }
                box.appendChild(row);
            });
        }

        async function loadSettings() {
            try {
                const res = await api('/api/settings');
                if (res.status === 401) return;
                renderSettings(await res.json());
            } catch (e) {}
        }

        async function setSetting(key, value) {
            const res = await api('/api/settings', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ key: key, value: value })
            });
            if (res.ok) renderSettings(await res.json());
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

      // Prefer the home LAN range the panel is meant to serve.
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && addr.address.startsWith('192.168.')) {
            return addr.address;
          }
        }
      }

      // In strict mode we deliberately do NOT fall back to some other
      // interface (cellular/VPN); binding there would expose the panel
      // outside the home LAN.
      if (strictLan) return '127.0.0.1';

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
