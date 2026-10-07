// The shared golden fixtures, asserted by the Dart codec too.
//
// The fixtures live at the repo root in `protocol/fixtures/`; `flutter test`
// runs with its cwd at `app/`, so `../protocol/...` reaches them (the mechanism
// proven by `app/test/fixtures_reachable_test.dart`).
//
// Decoding is necessary but far from sufficient: both codecs echo their parsed
// input, so `ok:true` alone is satisfied by a stub. `valid/expectations.json`
// supplies the independently-authored decoded field values each fixture must
// produce. `event-tool.json` pins the contract shape a relayed `kind:"tool"`
// payload must have; the bridge emits it from M2 on.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/attachment.dart';
import 'package:pi_handset/client/hub_client.dart';
import 'package:pi_handset/client/settle_notification.dart';
import 'package:pi_handset/protocol/protocol.dart';

/// `expectations.json` is metadata, not a message fixture.
bool isMessageFixture(String name) =>
    name.endsWith('.json') && name != 'expectations.json';

List<File> validFixtures() {
  final directory = Directory('../protocol/fixtures/valid');
  final files = directory
      .listSync()
      .whereType<File>()
      .where((file) => isMessageFixture(file.uri.pathSegments.last))
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// Descends [expected] into [actual]; returns the path of the first mismatch, or
/// null when every field named in [expected] holds. Objects match as a recursive
/// subset (an expectation need not restate the whole envelope); arrays match in
/// full.
String? firstMismatch(Object? expected, Object? actual, String path) {
  if (expected is Map) {
    if (actual is! Map) return '$path: expected an object, got ${actual.runtimeType}';
    for (final entry in expected.entries) {
      final key = entry.key;
      if (!actual.containsKey(key)) return '$path.$key is missing from the decoded value';
      final mismatch = firstMismatch(entry.value, actual[key], '$path.$key');
      if (mismatch != null) return mismatch;
    }
    return null;
  }
  if (expected is List) {
    if (actual is! List) return '$path: expected a list, got ${actual.runtimeType}';
    if (actual.length != expected.length) {
      return '$path: expected ${expected.length} items, got ${actual.length}';
    }
    for (var index = 0; index < expected.length; index++) {
      final mismatch = firstMismatch(expected[index], actual[index], '$path[$index]');
      if (mismatch != null) return mismatch;
    }
    return null;
  }
  if (expected != actual) {
    return '$path: expected ${jsonEncode(expected)}, got ${jsonEncode(actual)}';
  }
  return null;
}

void main() {
  final contract =
      jsonDecode(File('../protocol/contract.json').readAsStringSync())
          as Map<String, dynamic>;
  final expectationsFile =
      jsonDecode(
            File('../protocol/fixtures/valid/expectations.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final expectations = expectationsFile.entries
      .where((entry) => !entry.key.startsWith('_'))
      .toList();

  test('every valid fixture decodes', () {
    for (final file in validFixtures()) {
      final result = decode(file.readAsStringSync());
      expect(
        result.ok,
        isTrue,
        reason: '${file.path} must decode: ${result.code} ${result.error}',
      );
    }
  });

  test('every valid fixture decodes to its expected field values', () {
    final byFile = {for (final entry in expectations) entry.key: entry.value};
    for (final file in validFixtures()) {
      final name = file.uri.pathSegments.last;
      expect(byFile.containsKey(name), isTrue, reason: 'no expectation entry for $name');
      final result = decode(file.readAsStringSync());
      expect(result.ok, isTrue, reason: '$name must decode');
      final mismatch = firstMismatch(byFile[name], result.value, name);
      expect(mismatch, isNull, reason: '$name expectation failed');
    }
  });

  test('every valid fixture has an expectation entry and every entry names a fixture', () {
    final fixtures = validFixtures().map((file) => file.uri.pathSegments.last).toSet();
    final named = expectations.map((entry) => entry.key).toSet();
    for (final file in fixtures) {
      expect(named, contains(file), reason: 'no expectation entry for valid fixture: $file');
    }
    for (final file in named) {
      expect(fixtures, contains(file), reason: 'expectation entry names no valid fixture: $file');
    }
  });

  // Demoted: decode echoes its input, so this proves only that no field was
  // dropped in the decode→encode round trip, never that a field was validated.
  test('encode re-encodes every valid fixture without dropping or adding a field', () {
    for (final file in validFixtures()) {
      final raw = file.readAsStringSync();
      final result = decode(raw);
      expect(result.ok, isTrue, reason: '${file.path} must decode');
      expect(
        jsonDecode(encode(result.value!)),
        jsonDecode(raw),
        reason: '${file.path} must round-trip',
      );
    }
  });

  test('every message type the protocol defines has a valid fixture', () {
    final covered = <String>{};
    for (final file in validFixtures()) {
      final result = decode(file.readAsStringSync());
      expect(result.ok, isTrue, reason: '${file.path} must decode');
      covered.add(result.value!['type'] as String);
    }
    for (final type in allMessageTypes.toSet()) {
      expect(covered, contains(type), reason: 'no valid fixture for message type: $type');
    }
  });

  test('every event payload kind has a valid fixture', () {
    final covered = <String>{};
    for (final file in validFixtures()) {
      final result = decode(file.readAsStringSync());
      if (result.ok && result.value!['type'] == 'event') {
        covered.add((result.value!['payload'] as Map)['kind'] as String);
      }
    }
    for (final kind in eventPayloadKinds) {
      expect(covered, contains(kind), reason: 'no valid fixture for event payload kind: $kind');
    }
  });

  test('every declared view type has a valid fixture', () {
    final covered = <String>{};
    for (final file in validFixtures()) {
      final result = decode(file.readAsStringSync());
      if (!result.ok || result.value!['type'] != 'event') continue;
      final view = (result.value!['payload'] as Map)['view'];
      if (view is Map && view['type'] is String) covered.add(view['type'] as String);
    }
    for (final type in viewTypes) {
      expect(covered, contains(type), reason: 'no valid fixture for view type: $type');
    }
  });

  // Ties the canonical lists to `decode`. Dart has no runtime view of the
  // switch arms, so this one-way check is what stops a type missing from a list
  // from shipping green with no fixture demanded.
  test('every message type in the canonical lists decodes from a minimal body', () {
    final minimalBodies = <String, Map<String, Object?>>{
      'hello': {'protocolVersion': 1, 'type': 'hello', 'ticket': 'ABCD2345'},
      'register': {'protocolVersion': 1, 'type': 'register', 'sessionId': 'sess'},
      'event': {
        'protocolVersion': 1,
        'type': 'event',
        'payload': {'kind': 'stream', 'seq': 1, 'text': ''},
      },
      'history': {
        'protocolVersion': 1,
        'type': 'history',
        'sessionId': 'sess',
        'entries': <Object?>[],
        'truncated': false,
      },
      'command-result': {
        'protocolVersion': 1,
        'type': 'command-result',
        'id': 'id',
        'ok': true,
      },
      'subscribe': {'protocolVersion': 1, 'type': 'subscribe', 'sessionId': 'sess'},
      'unsubscribe': {'protocolVersion': 1, 'type': 'unsubscribe', 'sessionId': 'sess'},
      'history-request': {
        'protocolVersion': 1,
        'type': 'history-request',
        'sessionId': 'sess',
      },
      'command': {
        'protocolVersion': 1,
        'type': 'command',
        'id': 'id',
        'sessionId': 'sess',
        'name': 'prompt',
      },
      'start-session': {
        'protocolVersion': 1,
        'type': 'start-session',
        'id': 'start-1',
      },
      'kill-session': {
        'protocolVersion': 1,
        'type': 'kill-session',
        'id': 'kill-1',
        'sessionId': 'sess',
      },
      'paired': {'protocolVersion': 1, 'type': 'paired', 'token': 'tok'},
      'sessions': {
        'protocolVersion': 1,
        'type': 'sessions',
        'sessions': <Object?>[],
      },
      'snapshot': {
        'protocolVersion': 1,
        'type': 'snapshot',
        'sessionId': 'sess',
        'lastSeq': 0,
        'agentState': 'idle',
        'entries': <Object?>[],
        'truncated': false,
      },
      'resync-required': {
        'protocolVersion': 1,
        'type': 'resync-required',
        'sessionId': 'sess',
        'reason': 'r',
      },
      'spawn-failed': {
        'protocolVersion': 1,
        'type': 'spawn-failed',
        'id': 'pending-1',
        'error': 'failed',
      },
      'session-gone': {'protocolVersion': 1, 'type': 'session-gone', 'sessionId': 'sess'},
      'agent-settled': {
        'protocolVersion': 1,
        'type': 'agent-settled',
        'sessionId': 'sess',
        'label': 'work',
        'text': 'Done.',
        'truncated': false,
      },
      'list-dirs': {'protocolVersion': 1, 'type': 'list-dirs', 'id': 'dirs-1'},
      'dir-listing': {
        'protocolVersion': 1,
        'type': 'dir-listing',
        'id': 'dirs-1',
        'path': '/home/user',
        'root': '/home/user',
        'trust': null,
        'trustRequired': false,
        'entries': <Object?>[],
        'truncated': false,
      },
    };
    for (final type in allMessageTypes) {
      final body = minimalBodies[type];
      expect(body, isNotNull, reason: 'no minimal body for message type: $type');
      final result = decode(jsonEncode(body));
      expect(result.ok, isTrue, reason: '$type must decode from its minimal body');
      expect(result.value!['type'], type, reason: 'decoding $type must yield type $type');
    }
  });

  // Cross-language pin: both suites assert their own lists against this shared
  // fixture, so a list dropped in one language fails that language's suite.
  test('the canonical message-type and payload-kind lists match the shared fixture', () {
    final shared =
        jsonDecode(
              File('../protocol/contract.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(allMessageTypes.toSet(), (shared['messageTypes'] as List).toSet());
    expect(eventPayloadKinds.toSet(), (shared['eventPayloadKinds'] as List).toSet());
    expect(streamPhases.toSet(), (shared['streamPhases'] as List).toSet());
    expect(agentMessageTypes.toSet(), (shared['agentMessageTypes'] as List).toSet());
    expect(viewerMessageTypes.toSet(), (shared['viewerMessageTypes'] as List).toSet());
    expect(
      hubToViewerMessageTypes.toSet(),
      (shared['hubToViewerMessageTypes'] as List).toSet(),
    );
    expect(sessionOrigins.toSet(), (shared['sessionOrigins'] as List).toSet());
    expect(hubCapabilities.toSet(), (shared['hubCapabilities'] as List).toSet());
    expect(toolStatuses.toSet(), (shared['toolStatuses'] as List).toSet());
    expect(agentStates.toSet(), (shared['agentStates'] as List).toSet());
    expect(viewTypes.toSet(), (shared['viewTypes'] as List).toSet());
  });

  test('every invalid fixture is rejected for the right reason', () {
    final index =
        jsonDecode(File('../protocol/fixtures/invalid/cases.json').readAsStringSync())
            as Map<String, dynamic>;
    final cases = index['cases'] as List;
    expect(cases, isNotEmpty, reason: 'cases.json must name at least one case');
    for (final entry in cases) {
      final testCase = entry as Map<String, dynamic>;
      final raw = File(
        '../protocol/fixtures/invalid/${testCase['file']}',
      ).readAsStringSync();
      final result = decode(raw);
      expect(result.ok, isFalse, reason: '${testCase['file']} must be rejected');
      expect(
        result.code,
        testCase['code'],
        reason: '${testCase['file']} must be rejected as ${testCase['code']}',
      );
    }
  });

  test('every invalid fixture is named in cases.json and vice versa', () {
    final directory = Directory('../protocol/fixtures/invalid');
    final files =
        directory
            .listSync()
            .whereType<File>()
            .map((file) => file.uri.pathSegments.last)
            .where((name) => name != 'cases.json')
            .toList()
          ..sort();
    final named =
        (jsonDecode(File('../protocol/fixtures/invalid/cases.json').readAsStringSync())
                as Map<String, dynamic>)['cases']
            .map((Object? entry) => (entry as Map<String, dynamic>)['file'] as String)
            .toList()
          ..sort();
    expect(
      files,
      named,
      reason: 'invalid/ must contain exactly the fixtures cases.json names',
    );
  });

  test('the protocol numbers match the shared contract', () {
    expect(
      protocolVersion,
      contract['protocolVersion'],
      reason: 'protocolVersion must equal contract.protocolVersion',
    );
    expect(
      closeCapability,
      contract['closeCodes']['capability'],
      reason: 'closeCapability must equal contract.closeCodes.capability',
    );
    expect(
      closeRateLimited,
      contract['closeCodes']['rateLimited'],
      reason: 'closeRateLimited must equal contract.closeCodes.rateLimited',
    );
    expect(
      maxAttachmentBytes,
      contract['byteCaps']['attachment'],
      reason: 'maxAttachmentBytes must equal contract.byteCaps.attachment',
    );
    expect(
      notificationBodyMaxCodePoints,
      contract['codePointCaps']['notificationBody'],
      reason: 'notificationBodyMaxCodePoints must equal contract.codePointCaps.notificationBody',
    );
  });

  // The invariants read only the contract; the equality test above reads only
  // the language constants. A constant that moves is caught by that side's
  // equality test, and a contract value that moves by the invariants in both
  // suites.
  test("an attachment's base64 form fits the hub frame", () {
    expect(
      contract['byteCaps']['attachment'] * 4 <= contract['byteCaps']['hubFrame'] * 3,
      isTrue,
      reason: "contract: an attachment's base64 form must fit the hub frame",
    );
  });

  test('the visible body cap stays within the wire settled-text cap', () {
    expect(
      contract['codePointCaps']['notificationBody'] <= contract['codePointCaps']['settledText'],
      isTrue,
      reason: 'contract: the visible body cap must not exceed the wire settled-text cap',
    );
  });

  test('a tool view is smaller than the relay budget', () {
    expect(
      contract['byteCaps']['toolView'] < contract['byteCaps']['relay'],
      isTrue,
      reason: 'contract: a tool view must be smaller than the relay budget',
    );
  });

  test('a history page is larger than the relay budget', () {
    expect(
      contract['byteCaps']['history'] > contract['byteCaps']['relay'],
      isTrue,
      reason: 'contract: a history page must be larger than the relay budget',
    );
  });
}
