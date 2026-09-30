// Dedicated `sessions` codec branches. The two invalid fixtures prove the wire
// shape end to end; these pin the per-branch rejections (and the deliberate
// absence of `lastSeq`) that a fixture pair cannot express without six
// near-identical files.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/protocol/protocol.dart';

Map<String, Object?> _message(Object? sessions) => {
  'protocolVersion': protocolVersion,
  'type': 'sessions',
  'sessions': sessions,
};

void main() {
  test('a sessions summary decodes and carries no lastSeq', () {
    final result = decode(
      jsonEncode(
        _message([
          {'sessionId': 'sess-1', 'label': 'one', 'agentState': 'settled'},
        ]),
      ),
    );
    expect(result.ok, isTrue);
    final entry = (result.value!['sessions'] as List).single as Map;
    expect(entry.keys.toSet(), {'sessionId', 'label', 'agentState'});
  });

  test('rejects a sessions list that is not an array', () {
    final result = decode(jsonEncode(_message('nope')));
    expect(result.ok, isFalse);
    expect(result.code, 'bad-field');
  });

  test('rejects a sessions entry that is not an object', () {
    final result = decode(jsonEncode(_message([42])));
    expect(result.ok, isFalse);
    expect(result.code, 'bad-field');
  });

  test('rejects a sessions entry with a missing sessionId', () {
    final result = decode(
      jsonEncode(
        _message([
          {'label': 'one', 'agentState': 'idle'},
        ]),
      ),
    );
    expect(result.ok, isFalse);
    expect(result.code, 'bad-field');
  });

  test('rejects a sessions entry with an empty sessionId', () {
    final result = decode(
      jsonEncode(
        _message([
          {'sessionId': '', 'label': 'one', 'agentState': 'idle'},
        ]),
      ),
    );
    expect(result.ok, isFalse);
    expect(result.code, 'bad-field');
  });

  test('rejects a sessions entry with a non-string label', () {
    final result = decode(
      jsonEncode(
        _message([
          {'sessionId': 'sess-1', 'label': 42, 'agentState': 'idle'},
        ]),
      ),
    );
    expect(result.ok, isFalse);
    expect(result.code, 'bad-field');
  });

  test('rejects a sessions entry with an unknown agentState', () {
    final result = decode(
      jsonEncode(
        _message([
          {'sessionId': 'sess-1', 'label': 'one', 'agentState': 'done'},
        ]),
      ),
    );
    expect(result.ok, isFalse);
    expect(result.code, 'bad-state');
  });
}
