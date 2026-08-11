import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// TV Remote Configuration Server
/// Provides a web interface accessible from mobile devices to:
/// - Login to Bilibili account (QR code or credentials)
/// - Configure app settings
/// - Control playback remotely
class TVRemoteServer {
  static TVRemoteServer? _instance;
  HttpServer? _server;
  int? _port;
  String? _localIP;
  final _streamController = StreamController<String>.broadcast();

  TVRemoteServer._();

  static TVRemoteServer get instance {
    _instance ??= TVRemoteServer._();
    return _instance!;
  }

  /// Start the remote configuration server
  Future<bool> start({int port = 8888}) async {
    if (_server != null) {
      debugPrint('TV Remote Server already running on port $_port');
      return true;
    }

    try {
      _localIP = await _getLocalIP();
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

  /// Stop the server
  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _port = null;
    debugPrint('TV Remote Server stopped');
  }

  bool get isRunning => _server != null;
  String? get serverURL => _localIP != null && _port != null 
      ? 'http://$_localIP:$_port' 
      : null;

  void _handleRequest(HttpRequest request) {
    final response = request.response;

    // CORS headers for mobile browser access
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.ok;
      response.close();
      return;
    }

    final path = request.uri.path;

    try {
      switch (path) {
        case '/':
          _serveIndexPage(response);
          break;
        case '/api/status':
          _serveStatus(response);
          break;
        case '/api/login/qr':
          _handleQRLogin(request, response);
          break;
        case '/api/settings':
          _handleSettings(request, response);
          break;
        case '/api/control':
          _handleControl(request, response);
          break;
        default:
          response.statusCode = HttpStatus.notFound;
          response.write('Not Found');
          response.close();
      }
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.write('Server Error: $e');
      response.close();
    }
  }

  void _serveIndexPage(HttpResponse response) {
    response.headers.contentType = ContentType.html;
    response.write(_buildWebUI());
    response.close();
  }

  void _serveStatus(HttpResponse response) {
    response.headers.contentType = ContentType.json;
    final status = {
      'server': 'running',
      'version': '1.0.0',
      'device': 'Android TV',
    };
    response.write(jsonEncode(status));
    response.close();
  }

  Future<void> _handleQRLogin(HttpRequest request, HttpResponse response) async {
    if (request.method == 'GET') {
      // Return QR login URL (implement actual Bilibili QR login flow)
      response.headers.contentType = ContentType.json;
      final qrData = {
        'qr_url': 'https://passport.bilibili.com/qrcode/getLoginUrl',
        'status': 'pending',
      };
      response.write(jsonEncode(qrData));
      response.close();
    }
  }

  Future<void> _handleSettings(HttpRequest request, HttpResponse response) async {
    response.headers.contentType = ContentType.json;

    if (request.method == 'GET') {
      // Return current settings
      final settings = {
        'volume': 50,
        'quality': 'auto',
        'danmaku_enabled': true,
      };
      response.write(jsonEncode(settings));
    } else if (request.method == 'POST') {
      // Update settings
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body);
      
      // Apply settings (integrate with actual app settings)
      debugPrint('Received settings update: $data');
      
      response.write(jsonEncode({'success': true}));
    }

    response.close();
  }

  Future<void> _handleControl(HttpRequest request, HttpResponse response) async {
    if (request.method != 'POST') {
      response.statusCode = HttpStatus.methodNotAllowed;
      response.close();
      return;
    }

    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body);
    final action = data['action'];

    // Broadcast control action
    _streamController.add(action);

    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({'success': true, 'action': action}));
    response.close();
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
        .subtitle {
            color: #8B92A0;
            font-size: 14px;
            margin-bottom: 32px;
        }
        .card {
            background: #161D2B;
            border-radius: 16px;
            padding: 24px;
            margin-bottom: 16px;
            border: 1px solid rgba(56, 189, 248, 0.1);
        }
        .card h2 {
            font-size: 18px;
            margin-bottom: 16px;
            color: #38BDF8;
        }
        button {
            width: 100%;
            padding: 16px;
            border: none;
            border-radius: 12px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s;
            margin-bottom: 12px;
        }
        .btn-primary {
            background: linear-gradient(135deg, #38BDF8 0%, #3B6DFF 100%);
            color: white;
        }
        .btn-primary:active {
            transform: scale(0.98);
            opacity: 0.9;
        }
        .btn-secondary {
            background: #1E2636;
            color: #E0E6ED;
            border: 1px solid rgba(56, 189, 248, 0.2);
        }
        .qr-container {
            background: white;
            padding: 20px;
            border-radius: 12px;
            text-align: center;
            margin: 16px 0;
        }
        .qr-placeholder {
            width: 200px;
            height: 200px;
            margin: 0 auto;
            background: #f0f0f0;
            border-radius: 8px;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #666;
        }
        .control-grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 12px;
            margin-top: 16px;
        }
        .control-grid button {
            padding: 20px;
            font-size: 24px;
            margin: 0;
        }
        .center { text-align: center; }
        .status {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 999px;
            font-size: 12px;
            background: rgba(56, 189, 248, 0.1);
            color: #38BDF8;
            margin-bottom: 16px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>PiliPlus TV 遥控器</h1>
        <p class="subtitle">通过手机控制你的电视端 PiliPlus</p>

        <div class="card">
            <h2>账号登录</h2>
            <div class="status">● 连接成功</div>
            <button class="btn-primary" onclick="showQR()">扫码登录</button>
            <div id="qrCode" class="qr-container" style="display:none;">
                <div class="qr-placeholder">二维码加载中...</div>
                <p style="color: #666; margin-top: 12px; font-size: 14px;">
                    使用 B 站 APP 扫码登录
                </p>
            </div>
        </div>

        <div class="card">
            <h2>播放控制</h2>
            <div class="control-grid">
                <button class="btn-secondary" onclick="control('up')">↑</button>
                <button class="btn-secondary" onclick="control('volume_up')">🔊</button>
                <button class="btn-secondary" onclick="control('seek_forward')">⏩</button>
                
                <button class="btn-secondary" onclick="control('left')">←</button>
                <button class="btn-primary" onclick="control('play_pause')">⏯</button>
                <button class="btn-secondary" onclick="control('right')">→</button>
                
                <button class="btn-secondary" onclick="control('down')">↓</button>
                <button class="btn-secondary" onclick="control('volume_down')">🔉</button>
                <button class="btn-secondary" onclick="control('seek_backward')">⏪</button>
            </div>
        </div>

        <div class="card">
            <h2>快捷功能</h2>
            <button class="btn-secondary" onclick="control('back')">返回</button>
            <button class="btn-secondary" onclick="control('home')">主页</button>
            <button class="btn-secondary" onclick="control('search')">搜索</button>
        </div>
    </div>

    <script>
        function showQR() {
            const qrDiv = document.getElementById('qrCode');
            qrDiv.style.display = qrDiv.style.display === 'none' ? 'block' : 'none';
            
            if (qrDiv.style.display === 'block') {
                fetch('/api/login/qr')
                    .then(r => r.json())
                    .then(data => {
                        console.log('QR data:', data);
                        // TODO: Render actual QR code
                    });
            }
        }

        function control(action) {
            fetch('/api/control', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action })
            })
            .then(r => r.json())
            .then(data => {
                console.log('Control response:', data);
                // Visual feedback
                event.target.style.transform = 'scale(0.95)';
                setTimeout(() => {
                    event.target.style.transform = 'scale(1)';
                }, 100);
            })
            .catch(err => console.error('Control error:', err));
        }

        // Check server status on load
        fetch('/api/status')
            .then(r => r.json())
            .then(data => console.log('Server status:', data))
            .catch(err => console.error('Status check failed:', err));
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
          // Prefer non-loopback addresses
          if (!addr.isLoopback && addr.address.startsWith('192.168.')) {
            return addr.address;
          }
        }
      }

      // Fallback to first non-loopback
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
