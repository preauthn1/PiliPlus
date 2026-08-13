import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final server = File('lib/services/tv_remote_server.dart').readAsStringSync();
  final provider = File('lib/services/tv_remote_provider.dart').readAsStringSync();
  final panel = File('lib/pages/tv_remote_panel/view.dart').readAsStringSync();

  test('logs endpoint is paired, GET-only and non-cacheable', () {
    expect(server, contains("case '/api/logs':"));
    expect(server, contains('await _handleLogs(request, response);'));
    expect(server, contains("request.method != 'GET'"));
    expect(server, contains("HttpHeaders.cacheControlHeader, 'no-store'"));
    expect(
      server,
      contains('Future<Map<String, dynamic>> Function(int limit)? _logsSnapshot'),
    );
  });

  test('provider exports recent error text and complete stack traces', () {
    expect(
      provider,
      contains('Future<Map<String, dynamic>> logsSnapshot(int limit)'),
    );
    expect(provider, contains('LoggerUtils.getLogsPath()'));
    expect(provider, contains('Report.fromJson'));
    expect(provider, contains("'stackTrace': stackTrace"));
    expect(provider, contains("'copyText':"));
  });

  test('web UI supports refresh, per-item copy and copy-all', () {
    expect(server, contains('id="logsBox"'));
    expect(server, contains('onclick="loadLogs()"'));
    expect(server, contains('onclick="copyAllLogs()"'));
    expect(server, contains("api('/api/logs?limit='"));
    expect(server, contains('navigator.clipboard.writeText'));
    expect(server, contains('复制这条日志'));
  });

  test('TV panel binds the logs provider', () {
    expect(panel, contains('logs: provider.logsSnapshot,'));
  });
}
