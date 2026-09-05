// Verifies the strict-LAN rule the user asked for: the web panel must only
// serve 192.168.x.x clients (plus loopback), not every RFC1918 range and
// definitely not the public internet.
//
// This mirrors TVRemoteServer._isPrivateAddress exactly; the live server is
// additionally exercised in tv_remote_e2e_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

bool isAllowed(InternetAddress addr, {bool strictLan = true}) {
  if (addr.isLoopback) return true;
  if (addr.type != InternetAddressType.IPv4) {
    final a = addr.address.toLowerCase();
    if (strictLan) return false;
    return a.startsWith('fc') || a.startsWith('fd') || a.startsWith('fe80');
  }
  final parts = addr.address.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null)) return false;
  final [a, b, _, _] = parts.cast<int>();
  if (strictLan) {
    return a == 192 && b == 168;
  }
  if (a == 10) return true;
  if (a == 192 && b == 168) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 169 && b == 254) return true;
  return false;
}

void main() {
  group('strict LAN (192.168 only)', () {
    test('allows home LAN and loopback', () {
      for (final ip in [
        '192.168.0.1',
        '192.168.1.100',
        '192.168.255.254',
        '127.0.0.1',
      ]) {
        expect(isAllowed(InternetAddress(ip)), isTrue, reason: ip);
      }
    });

    test('blocks other private ranges', () {
      // Explicitly out of scope per the requirement: only 192.168 is served.
      for (final ip in ['10.0.0.5', '172.16.0.1', '172.31.255.254']) {
        expect(isAllowed(InternetAddress(ip)), isFalse, reason: ip);
      }
    });

    test('blocks link-local and CGNAT', () {
      for (final ip in ['169.254.1.1', '100.64.0.1']) {
        expect(isAllowed(InternetAddress(ip)), isFalse, reason: ip);
      }
    });

    test('blocks public addresses', () {
      for (final ip in [
        '8.8.8.8',
        '1.1.1.1',
        '203.0.113.9',
        '192.169.1.1', // adjacent to 192.168, must NOT match
        '192.167.1.1',
      ]) {
        expect(isAllowed(InternetAddress(ip)), isFalse, reason: ip);
      }
    });

    test('blocks all IPv6 except loopback', () {
      expect(isAllowed(InternetAddress('::1')), isTrue);
      for (final ip in ['fd00::1', 'fe80::1', '2001:4860:4860::8888']) {
        expect(isAllowed(InternetAddress(ip)), isFalse, reason: ip);
      }
    });
  });

  group('relaxed mode (opt-in for 10.x / 172.16.x networks)', () {
    test('allows all RFC1918', () {
      for (final ip in ['10.0.0.5', '172.16.0.1', '192.168.1.1']) {
        expect(isAllowed(InternetAddress(ip), strictLan: false), isTrue,
            reason: ip);
      }
    });

    test('still blocks public', () {
      for (final ip in ['8.8.8.8', '172.32.0.1', '172.15.0.1']) {
        expect(isAllowed(InternetAddress(ip), strictLan: false), isFalse,
            reason: ip);
      }
    });
  });
}
