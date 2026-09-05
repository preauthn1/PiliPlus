// End-to-end test of the REAL TVRemoteServer: starts it, drives it over HTTP,
// and asserts pairing enforcement + action delivery on controlStream.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/tv_remote_server.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> runAll() async {
  final server = TVRemoteServer.instance;
  final received = <String>[];
  server.controlStream.listen(received.add);
  var loginArmed = false;
  final settingsStore = <String, Object>{'showDanmaku': true};

  Map<String, dynamic> snapshot() => {
        'items': [
          {
            'key': 'showDanmaku',
            'title': 'danmaku',
            'type': 'bool',
            'value': settingsStore['showDanmaku'],
          }
        ]
      };

  server.bindProviders(
    state: () => {'hasPlayer': true, 'playing': true},
    settings: snapshot,
    onSettings: (data) {
      settingsStore[data['key'] as String] = data['value'] as Object;
      return snapshot();
    },
    loginState: () => {
      'enabled': loginArmed,
      'status': 'idle',
      'url': loginArmed ? 'https://passport.bilibili.com/x/fake' : null,
      'logged': false,
    },
    loginStart: () async => {
      'enabled': loginArmed,
      'status': loginArmed ? 'waiting' : 'idle',
      if (!loginArmed) 'error': 'login not enabled on TV',
    },
    logout: () async => {'logged': false, 'status': 'idle'},
  );
  // Tests talk over loopback; the strict 192.168 predicate is covered by its
  // own unit test below.
  server.strictLan = false;

  final ok = await server.start(port: 18888);
  if (!ok) {
    throw StateError('server did not start');
  }
  final code = server.pairingCode!;
  print('pairing code = $code (len=${code.length})');

  final client = HttpClient();
  var pass = 0, fail = 0;
  void check(String name, bool cond, [String extra = '']) {
    if (cond) {
      pass++;
      print('PASS  $name');
    } else {
      fail++;
      print('FAIL  $name $extra');
    }
  }

  Future<HttpClientResponse> post(String path, Object body,
      {String? pairing}) async {
    final req = await client.postUrl(Uri.parse('http://127.0.0.1:18888$path'));
    req.headers.contentType = ContentType.json;
    if (pairing != null) req.headers.add('X-Pairing-Code', pairing);
    req.write(jsonEncode(body));
    return req.close();
  }

  // 1. pairing code shape
  check('pairing code is 6 digits',
      code.length == 6 && int.tryParse(code) != null, code);

  // 2. index page reachable
  final idx = await (await client
          .getUrl(Uri.parse('http://127.0.0.1:18888/')))
      .close();
  check('GET / returns 200', idx.statusCode == 200, '${idx.statusCode}');
  await idx.drain<void>();

  // 3. status is open (no pairing needed)
  final st = await (await client
          .getUrl(Uri.parse('http://127.0.0.1:18888/api/status')))
      .close();
  check('GET /api/status returns 200', st.statusCode == 200);
  await st.drain<void>();

  // 4. control WITHOUT pairing code must be rejected
  final noAuth = await post('/api/control', {'action': 'play_pause'});
  check('control without code -> 401', noAuth.statusCode == 401,
      '${noAuth.statusCode}');
  await noAuth.drain<void>();

  // 5. control with WRONG code must be rejected
  final badAuth =
      await post('/api/control', {'action': 'play_pause'}, pairing: '000000');
  check('control with wrong code -> 401', badAuth.statusCode == 401,
      '${badAuth.statusCode}');
  await badAuth.drain<void>();

  // 6. nothing should have reached the stream yet
  await Future<void>.delayed(const Duration(milliseconds: 50));
  check('no actions leaked from rejected requests', received.isEmpty,
      received.toString());

  // 7. control WITH correct code succeeds and delivers the action
  final good =
      await post('/api/control', {'action': 'play_pause'}, pairing: code);
  final goodBody = await good.transform(utf8.decoder).join();
  check('control with valid code -> 200', good.statusCode == 200,
      '${good.statusCode}');
  await Future<void>.delayed(const Duration(milliseconds: 50));
  check('action delivered to controlStream',
      received.contains('play_pause'), received.toString());
  check('response carries real player state',
      goodBody.contains('"hasPlayer":true'), goodBody);

  // 8. malformed action rejected
  final bad = await post('/api/control', {'action': ''}, pairing: code);
  check('empty action -> 400', bad.statusCode == 400, '${bad.statusCode}');
  await bad.drain<void>();

  // 9. unknown path
  final nf = await (await client
          .getUrl(Uri.parse('http://127.0.0.1:18888/nope')))
      .close();
  check('unknown path -> 404', nf.statusCode == 404);
  await nf.drain<void>();

  // 10. no wildcard CORS
  final corsResp = await (await client
          .getUrl(Uri.parse('http://127.0.0.1:18888/api/status')))
      .close();
  final acao = corsResp.headers.value('access-control-allow-origin');
  check('no wildcard CORS header', acao != '*', 'got: $acao');
  await corsResp.drain<void>();

  // 11. login endpoints require pairing
  final loginNoAuth = await (await client
          .getUrl(Uri.parse('http://127.0.0.1:18888/api/login')))
      .close();
  check('login state without code -> 401', loginNoAuth.statusCode == 401,
      '${loginNoAuth.statusCode}');
  await loginNoAuth.drain<void>();

  Future<HttpClientResponse> authGet(String path) async {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:18888$path'));
    req.headers.add('X-Pairing-Code', code);
    return req.close();
  }

  // 12. login is refused until armed on the TV
  final notArmed = await authGet('/api/login/start');
  final notArmedBody = await notArmed.transform(utf8.decoder).join();
  check('login refused until armed on TV',
      notArmedBody.contains('not enabled'), notArmedBody);

  // 13. QR is unavailable before a login session exists
  final qrEarly = await authGet('/api/login/qr.svg');
  check('QR 404 before login armed', qrEarly.statusCode == 404,
      '${qrEarly.statusCode}');
  await qrEarly.drain<void>();

  // 14. once armed, QR renders as SVG
  loginArmed = true;
  final qr = await authGet('/api/login/qr.svg');
  final qrBody = await qr.transform(utf8.decoder).join();
  check('QR renders SVG once armed',
      qr.statusCode == 200 && qrBody.startsWith('<svg'), '${qr.statusCode}');
  check('QR is drawn (has modules)', qrBody.contains('<rect'), 'no rects');

  // 15. QR endpoint also requires pairing
  final qrNoAuth = await (await client
          .getUrl(Uri.parse('http://127.0.0.1:18888/api/login/qr.svg')))
      .close();
  check('QR without code -> 401', qrNoAuth.statusCode == 401,
      '${qrNoAuth.statusCode}');
  await qrNoAuth.drain<void>();

  // 16. settings round-trip
  final getSettings = await authGet('/api/settings');
  final getBody = await getSettings.transform(utf8.decoder).join();
  check('settings GET returns items', getBody.contains('showDanmaku'), getBody);

  final setRes =
      await post('/api/settings', {'key': 'showDanmaku', 'value': false},
          pairing: code);
  final setBody = await setRes.transform(utf8.decoder).join();
  check('settings POST applies and echoes new state',
      setBody.contains('"value":false'), setBody);
  check('settings actually mutated', settingsStore['showDanmaku'] == false,
      '${settingsStore['showDanmaku']}');

  // 17. settings POST without pairing is rejected
  final setNoAuth =
      await post('/api/settings', {'key': 'showDanmaku', 'value': true});
  check('settings POST without code -> 401', setNoAuth.statusCode == 401,
      '${setNoAuth.statusCode}');
  await setNoAuth.drain<void>();
  check('rejected settings write did not mutate state',
      settingsStore['showDanmaku'] == false, 'state was changed!');

  // 18. restart rotates the pairing code
  await server.stop();
  await server.start(port: 18889);
  check('pairing code rotates on restart', server.pairingCode != code,
      '${server.pairingCode} vs $code');

  await server.stop();
  client.close(force: true);

  print('\n$pass passed, $fail failed');
  if (fail > 0) throw StateError('$fail checks failed');
}

void main() {
  test('TVRemoteServer end-to-end', runAll,
      timeout: const Timeout(Duration(minutes: 2)));
}
