// Dart-only edges for the `pidroid://pair` codec. The shared vectors are
// covered by `pairing_vectors_test.dart`; this file pins the classifier ranges
// and the parse semantics the PC parser has and the vectors do not spell out.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/protocol/pairing_uri.dart';

PairingOk _ok(String uri) {
  final result = parsePairingUri(uri);
  expect(result, isA<PairingOk>(), reason: 'expected $uri to parse, got $result');
  return result as PairingOk;
}

String _error(String uri) {
  final result = parsePairingUri(uri);
  expect(result, isA<PairingFailure>(), reason: 'expected $uri to fail, got $result');
  return (result as PairingFailure).error;
}

void main() {
  group('classifyAddress', () {
    test('classifies every RFC1918 range at both edges', () {
      expect(classifyAddress('10.0.0.0'), PairingAddressKind.lan);
      expect(classifyAddress('10.255.255.255'), PairingAddressKind.lan);
      expect(classifyAddress('172.16.0.0'), PairingAddressKind.lan);
      expect(classifyAddress('172.31.255.255'), PairingAddressKind.lan);
      expect(classifyAddress('192.168.0.0'), PairingAddressKind.lan);
      expect(classifyAddress('192.168.255.255'), PairingAddressKind.lan);
    });

    test('rejects one address past each RFC1918 edge', () {
      expect(classifyAddress('9.255.255.255'), isNull);
      expect(classifyAddress('11.0.0.0'), isNull);
      expect(classifyAddress('172.15.255.255'), isNull);
      expect(classifyAddress('172.32.0.0'), isNull);
      expect(classifyAddress('192.167.255.255'), isNull);
      expect(classifyAddress('192.169.0.0'), isNull);
    });

    test('classifies the 100.64/10 CGNAT range at both edges', () {
      expect(classifyAddress('100.64.0.0'), PairingAddressKind.ts);
      expect(classifyAddress('100.127.255.255'), PairingAddressKind.ts);
      expect(classifyAddress('100.63.255.255'), isNull);
      expect(classifyAddress('100.128.0.0'), isNull);
    });

    test('rejects hosts that are not a canonical dotted quad', () {
      expect(classifyAddress('example'), isNull);
      expect(classifyAddress('localhost'), isNull);
      expect(classifyAddress('8.8.8.8'), isNull);
      expect(classifyAddress('2001:db8::1'), isNull);
      expect(classifyAddress('192.168.1'), isNull);
      expect(classifyAddress('192.168.1.1.1'), isNull);
      expect(classifyAddress('192.168.1.'), isNull);
      expect(classifyAddress('.192.168.1.1'), isNull);
      expect(classifyAddress('192.168.1.256'), isNull);
      expect(classifyAddress('192.168.1.-1'), isNull);
      expect(classifyAddress('192.168.1.a'), isNull);
      expect(classifyAddress('192.168.1.1 '), isNull);
    });

    test('rejects leading-zero octets, matching Node isIPv4', () {
      expect(classifyAddress('010.0.0.1'), isNull);
      expect(classifyAddress('01.2.3.4'), isNull);
      expect(classifyAddress('192.168.001.1'), isNull);
      expect(classifyAddress('100.064.0.1'), isNull);
      expect(classifyAddress('100.64.00.1'), isNull);
    });
  });

  group('parsePairingUri', () {
    test('parses a canonical mixed URI and sorts LAN before TS', () {
      final pairing = _ok(
        'pidroid://pair?v=1&code=ABCD2345&port=8787'
        '&ts=100.64.1.2&lan=192.168.1.10',
      ).pairing;
      expect(pairing.code, 'ABCD2345');
      expect(pairing.viewerPort, 8787);
      expect(
        pairing.addresses.map((a) => '${a.kind.name}:${a.host}').toList(),
        ['lan:192.168.1.10', 'ts:100.64.1.2'],
      );
    });

    test('sorts same-kind addresses lexicographically, LAN then TS', () {
      final pairing = _ok(
        'pidroid://pair?v=1&code=ABCD2345&port=8787'
        '&lan=192.168.1.10&lan=10.0.0.5&ts=100.100.1.2&ts=100.64.1.2',
      ).pairing;
      expect(
        pairing.addresses.map((a) => a.host).toList(),
        ['10.0.0.5', '192.168.1.10', '100.100.1.2', '100.64.1.2'],
      );
    });

    test('never throws on malformed percent-encoding', () {
      for (final uri in const [
        'pidroid://pair?v=1&code=%ZZ',
        'pidroid://pair?v=1&code=%',
        'pidroid://pair?v=1&code=%A',
        'pidroid://pair?v=1&code=ABCD2345&port=%ZZ&lan=10.0.0.5',
        'pidroid://pair?v=1&code=ABCD2345&port=8787&lan=%ZZ',
      ]) {
        expect(
          parsePairingUri(uri),
          isA<PairingFailure>(),
          reason: '$uri must not throw',
        );
      }
    });

    test('reports unsupported-version when v is missing, future, or repeated', () {
      expect(_error('pidroid://pair?code=ABCD2345'), pairingErrorUnsupportedVersion);
      expect(_error('pidroid://pair?v=2&code=ABCD2345'), pairingErrorUnsupportedVersion);
      expect(
        _error('pidroid://pair?v=1&v=1&code=ABCD2345'),
        pairingErrorUnsupportedVersion,
      );
      expect(_error('pidroid://pair?v=&code=ABCD2345'), pairingErrorUnsupportedVersion);
    });

    test('duplicate port takes the first value, matching the PC', () {
      final pairing = _ok(
        'pidroid://pair?v=1&code=ABCD2345&port=8787&port=9999&lan=192.168.1.10',
      ).pairing;
      expect(pairing.viewerPort, 8787);
    });

    test('duplicate code takes the first value, matching the PC', () {
      final pairing = _ok(
        'pidroid://pair?v=1&code=ABCD2345&code=ZZZZ9999&port=8787&lan=192.168.1.10',
      ).pairing;
      expect(pairing.code, 'ABCD2345');
    });

    test('an uppercase scheme and host still parse', () {
      final pairing = _ok(
        'PIDROID://PAIR?v=1&code=ABCD2345&port=8787&lan=192.168.1.10',
      ).pairing;
      expect(pairing.code, 'ABCD2345');
      expect(pairing.viewerPort, 8787);
      expect(pairing.addresses.single.host, '192.168.1.10');
    });

    test('leading-zero octets are rejected by parse, not just the classifier', () {
      for (final host in const ['010.0.0.1', '01.2.3.4', '192.168.001.1']) {
        expect(
          _error('pidroid://pair?v=1&code=ABCD2345&port=8787&lan=$host'),
          pairingErrorInvalid,
          reason: 'lan=$host must be rejected',
        );
      }
    });

    test('port is present iff at least one address is present', () {
      final noAddresses = _ok('pidroid://pair?v=1&code=ABCD2345').pairing;
      expect(noAddresses.viewerPort, isNull);
      expect(noAddresses.addresses, isEmpty);

      expect(
        _error('pidroid://pair?v=1&code=ABCD2345&port=8787'),
        pairingErrorInvalid,
      );
      expect(
        _error('pidroid://pair?v=1&code=ABCD2345&lan=192.168.1.10'),
        pairingErrorInvalid,
      );
    });

    test('rejects a non-canonical or out-of-range port', () {
      for (final port in const ['0', '70000', '08787', '99999', 'abc']) {
        expect(
          _error('pidroid://pair?v=1&code=ABCD2345&port=$port&lan=192.168.1.10'),
          pairingErrorInvalid,
          reason: 'port=$port must be rejected',
        );
      }
    });

    test('rejects an address whose kind does not match its param', () {
      expect(
        _error('pidroid://pair?v=1&code=ABCD2345&port=8787&lan=8.8.8.8'),
        pairingErrorInvalid,
      );
      expect(
        _error('pidroid://pair?v=1&code=ABCD2345&port=8787&lan=100.64.1.2'),
        pairingErrorInvalid,
      );
      expect(
        _error('pidroid://pair?v=1&code=ABCD2345&port=8787&ts=192.168.1.10'),
        pairingErrorInvalid,
      );
    });

    test('rejects an invalid code', () {
      expect(_error('pidroid://pair?v=1&code=ABCD'), pairingErrorInvalid);
      expect(_error('pidroid://pair?v=1&code=ABCD234I'), pairingErrorInvalid);
      expect(_error('pidroid://pair?v=1'), pairingErrorInvalid);
    });

    test('rejects anything that is not a pidroid://pair URI', () {
      expect(_error('https://example.com/?v=1&code=ABCD2345'), pairingErrorNotAUri);
      expect(_error('pidroid://other?v=1&code=ABCD2345'), pairingErrorNotAUri);
      expect(_error('not a uri at all'), pairingErrorNotAUri);
      expect(_error(''), pairingErrorNotAUri);
    });

    test('ignores unknown params and is case-sensitive about known ones', () {
      final pairing = _ok(
        'pidroid://pair?v=1&code=ABCD2345&port=8787&lan=10.0.0.5'
        '&lan2=1.2.3.4&foo=bar&LAN=5.5.5.5',
      ).pairing;
      expect(pairing.addresses.single.host, '10.0.0.5');
    });

    test('normalizes a dashed lowercase code to the canonical form', () {
      final pairing = _ok(
        'pidroid://pair?v=1&code=abcd-2345&port=8787&lan=192.168.1.10',
      ).pairing;
      expect(pairing.code, 'ABCD2345');
    });
  });
}
