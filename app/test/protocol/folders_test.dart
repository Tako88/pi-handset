// Dart codec branch coverage for the folder-browsing message types.
//
// The shared fixtures pin one happy path and one wire shape each; these tests
// pin the accept/reject boundary fields the client and hub rely on, in the
// same spirit as `sessions_test.dart` for the pre-existing arms.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/protocol/protocol.dart';

Map<String, Object?> dirListing({
  Object? id = 'dirs-1',
  Object? path = '/home/user',
  Object? root = '/home/user',
  Object? trust,
  Object? trustRequired = false,
  Object? entries = const <Object?>[],
  Object? truncated = false,
}) => {
  'protocolVersion': 1,
  'type': 'dir-listing',
  'id': id,
  'path': path,
  'root': root,
  'trust': trust,
  'trustRequired': trustRequired,
  'entries': entries,
  'truncated': truncated,
};

DecodeResult decodeMap(Map<String, Object?> message) => decode(jsonEncode(message));

void main() {
  group('dir-listing', () {
    test('accepts trust null and trustRequired false', () {
      final result = decodeMap(dirListing());
      expect(result.ok, isTrue, reason: '${result.code} ${result.error}');
    });

    test('rejects a non-list entries field', () {
      final result = decodeMap(dirListing(entries: 'nope'));
      expect(result.ok, isFalse);
      expect(result.code, 'bad-field');
    });

    test('rejects a non-string entry', () {
      final result = decodeMap(dirListing(entries: const ['ok', 7]));
      expect(result.ok, isFalse);
      expect(result.code, 'bad-field');
    });

    test('rejects a non-boolean trustRequired', () {
      final result = decodeMap(dirListing(trustRequired: 'yes'));
      expect(result.ok, isFalse);
      expect(result.code, 'bad-field');
    });
  });

  group('list-dirs', () {
    test('accepts an absent path', () {
      final result = decodeMap({
        'protocolVersion': 1,
        'type': 'list-dirs',
        'id': 'dirs-1',
      });
      expect(result.ok, isTrue, reason: '${result.code} ${result.error}');
    });

    test('rejects an empty path', () {
      final result = decodeMap({
        'protocolVersion': 1,
        'type': 'list-dirs',
        'id': 'dirs-1',
        'path': '',
      });
      expect(result.ok, isFalse);
      expect(result.code, 'bad-field');
    });

    test('rejects an empty id', () {
      final result = decodeMap({'protocolVersion': 1, 'type': 'list-dirs', 'id': ''});
      expect(result.ok, isFalse);
      expect(result.code, 'bad-field');
    });
  });

  group('start-session', () {
    test('accepts cwd and trust', () {
      final result = decodeMap({
        'protocolVersion': 1,
        'type': 'start-session',
        'id': 'start-1',
        'cwd': '/home/user/project',
        'trust': true,
      });
      expect(result.ok, isTrue, reason: '${result.code} ${result.error}');
    });

    test('rejects a non-boolean trust', () {
      final result = decodeMap({
        'protocolVersion': 1,
        'type': 'start-session',
        'id': 'start-1',
        'trust': 'yes',
      });
      expect(result.ok, isFalse);
      expect(result.code, 'bad-field');
    });

    test('rejects an empty cwd', () {
      final result = decodeMap({
        'protocolVersion': 1,
        'type': 'start-session',
        'id': 'start-1',
        'cwd': '',
      });
      expect(result.ok, isFalse);
      expect(result.code, 'bad-field');
    });
  });

  group('sessions', () {
    test('accepts absent capabilities', () {
      final result = decodeMap({
        'protocolVersion': 1,
        'type': 'sessions',
        'sessions': <Object?>[],
      });
      expect(result.ok, isTrue, reason: '${result.code} ${result.error}');
    });

    test('rejects a non-list capabilities field', () {
      final result = decodeMap({
        'protocolVersion': 1,
        'type': 'sessions',
        'sessions': <Object?>[],
        'capabilities': 'nope',
      });
      expect(result.ok, isFalse);
      expect(result.code, 'bad-field');
    });

    test('rejects an empty capability string', () {
      final result = decodeMap({
        'protocolVersion': 1,
        'type': 'sessions',
        'sessions': <Object?>[],
        'capabilities': const [''],
      });
      expect(result.ok, isFalse);
      expect(result.code, 'bad-field');
    });
  });
}
