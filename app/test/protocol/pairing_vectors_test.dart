// The shared `pihandset://pair` vectors, asserted against the Dart port.
//
// The same file drives `pc/src/protocol/pairing-vectors.test.ts` against the
// TypeScript original, so the two parsers cannot drift silently. The Dart codec
// only ever consumes a hub-minted URI, so canonical vectors are parsed (this
// port has no formatter), not formatted.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/protocol/pairing_uri.dart';

void main() {
  final file =
      jsonDecode(
            File('../protocol/fixtures/pairing/vectors.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final vectors = (file['vectors'] as List).cast<Map<String, dynamic>>();

  test('the vector file pins version 1 and is not empty', () {
    expect(file['version'], 1);
    expect(vectors, isNotEmpty, reason: 'the vector file must not be empty');
  });

  test('every canonical and accepted vector parses to its pairing', () {
    final parsed = vectors.where((vector) => vector['kind'] != 'rejected');
    expect(parsed, isNotEmpty);
    for (final vector in parsed) {
      final name = vector['name'];
      final result = parsePairingUri(vector['uri'] as String);
      expect(result, isA<PairingOk>(), reason: '$name: expected a parse, got $result');
      final pairing = (result as PairingOk).pairing;
      final expected = vector['pairing'] as Map<String, dynamic>;

      expect(pairing.code, expected['code'], reason: '$name: code');
      expect(pairing.viewerPort, expected['viewerPort'], reason: '$name: viewerPort');

      final expectedAddresses = (expected['addresses'] as List)
          .cast<Map<String, dynamic>>();
      expect(
        pairing.addresses.map((address) => address.kind.name).toList(),
        expectedAddresses.map((address) => address['kind']).toList(),
        reason: '$name: address kinds',
      );
      expect(
        pairing.addresses.map((address) => address.host).toList(),
        expectedAddresses.map((address) => address['host']).toList(),
        reason: '$name: address hosts',
      );
    }
  });

  test('every rejected vector fails with its named error', () {
    final rejected = vectors.where((vector) => vector['kind'] == 'rejected');
    expect(rejected, isNotEmpty);
    for (final vector in rejected) {
      final name = vector['name'];
      final result = parsePairingUri(vector['uri'] as String);
      expect(result, isA<PairingFailure>(), reason: '$name: expected a failure, got $result');
      expect(
        (result as PairingFailure).error,
        vector['error'],
        reason: '$name: error',
      );
    }
  });
}
