import 'package:flutter/material.dart';
import 'package:PiliPlus/services/tv_remote_server.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// TV Remote Control Panel
/// Shows QR code and URL for mobile devices to connect
class TVRemotePanel extends StatefulWidget {
  const TVRemotePanel({super.key});

  @override
  State<TVRemotePanel> createState() => _TVRemotePanelState();
}

class _TVRemotePanelState extends State<TVRemotePanel> {
  final _server = TVRemoteServer.instance;
  bool _isStarting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (PlatformUtils.isTV) {
      _startServer();
    }
  }

  Future<void> _startServer() async {
    setState(() {
      _isStarting = true;
      _errorMessage = null;
    });

    try {
      final success = await _server.start();
      if (!success) {
        setState(() {
          _errorMessage = '启动服务失败';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '启动服务出错: $e';
      });
    } finally {
      setState(() {
        _isStarting = false;
      });
    }
  }

  @override
  void dispose() {
    // Keep server running in background
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformUtils.isTV) {
      return const Scaffold(
        body: Center(
          child: Text('此功能仅在 Android TV 上可用'),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0D12),
      appBar: AppBar(
        title: const Text('手机遥控'),
        backgroundColor: const Color(0xFF161D2B),
      ),
      body: _isStarting
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 64, color: Colors.red),
                      const SizedBox(height: 16),
                      Text(_errorMessage!),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _startServer,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _buildContent(),
    );
  }

  Widget _buildContent() {
    final serverURL = _server.serverURL;

    if (serverURL == null) {
      return const Center(
        child: Text('服务未启动'),
      );
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              '使用手机扫码',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '或在手机浏览器中输入以下地址',
              style: TextStyle(
                fontSize: 18,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 48),
            // QR Code
            Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: QrImageView(
                data: serverURL,
                version: QrVersions.auto,
                size: 300,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 48),
            // URL Display
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              decoration: BoxDecoration(
                color: const Color(0xFF161D2B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: SelectableText(
                serverURL,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF38BDF8),
                  letterSpacing: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 48),
            // Instructions
            _buildInstructionCard(
              icon: Icons.phone_android,
              title: '1. 使用手机扫码或输入网址',
              subtitle: '确保手机和电视在同一 WiFi 网络',
            ),
            const SizedBox(height: 16),
            _buildInstructionCard(
              icon: Icons.login,
              title: '2. 在手机上登录账号',
              subtitle: '扫描 B 站二维码快速登录',
            ),
            const SizedBox(height: 16),
            _buildInstructionCard(
              icon: Icons.settings,
              title: '3. 远程控制电视',
              subtitle: '播放控制、设置调整、搜索等',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionCard({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF161D2B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFF38BDF8).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: const Color(0xFF38BDF8),
              size: 28,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white60,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
