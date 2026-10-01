/// A hand-port of `pc/src/protocol/protocol.ts`'s envelope codec.
///
/// Pure `dart:convert` only: no Flutter imports, no packages. [decode] is the
/// validating boundary and never throws; [encode] trusts the map it is given.
/// The shared fixtures in `protocol/fixtures/` are asserted against both this
/// and the TypeScript original.
library;

import 'dart:convert';

/// The wire protocol version.
const int protocolVersion = 1;

/// The shared byte cap for agent-supplied bulk payloads.
const int maxRelayBytes = 256 * 1024;

/// The agent's reported lifecycle state.
const List<String> agentStates = ['idle', 'running', 'settled'];

/// Who started a session: the app (`app`) or the PC (`pc`). Derived hub-side
/// from the spawner's live children, never from a client claim.
const List<String> sessionOrigins = ['app', 'pc'];

/// The normalized payload kinds an `event` may carry.
const List<String> eventPayloadKinds = [
  'stream',
  'message',
  'agent',
  'tool',
  'status',
  'usage',
  'settled',
];

/// Lifecycle phases a `stream` frame may signal, and the tag that marks one.
///
/// `thinking` is emitted twice over: on `thinking_start` as a content-free
/// liveness signal (the frame carries no `text`), then on every
/// `thinking_delta` with that chunk in `text`. A frame carries `text` and/or
/// `phase`; at least one is required. The committed `message` stays
/// authoritative.
const List<String> streamPhases = ['thinking'];

/// The hub capabilities this protocol version advertises on the `sessions`
/// frame. Canonical; a viewer gates folder browsing on their presence.
const List<String> hubCapabilities = ['list-dirs', 'project-session'];

/// What the loopback (agent) listener accepts besides `hello`.
///
/// These lists are canonical: [decode]'s switch follows them, never the
/// reverse, and the fixture suite asserts each against the shared
/// `protocol/fixtures/message-types.json`.
const List<String> agentMessageTypes = [
  'register',
  'event',
  'history',
  'command-result',
];

/// What the LAN (viewer) listener accepts besides `hello`. Canonical; see
/// [agentMessageTypes].
const List<String> viewerMessageTypes = [
  'subscribe',
  'unsubscribe',
  'history-request',
  'command',
  'start-session',
  'kill-session',
  'list-dirs',
];

/// What the hub sends to a viewer. Canonical; see [agentMessageTypes].
const List<String> hubToViewerMessageTypes = [
  'paired',
  'sessions',
  'event',
  'snapshot',
  'command-result',
  'resync-required',
  'session-gone',
  'agent-settled',
  'dir-listing',
];

/// Every message type the protocol defines. The fixture suite asserts one valid
/// fixture per entry, so a type added here without a fixture fails the test.
const List<String> allMessageTypes = [
  'hello',
  ...agentMessageTypes,
  ...viewerMessageTypes,
  ...hubToViewerMessageTypes,
];

/// The outcome of [decode]. Mirrors `DecodeResult` in `protocol.ts`, including
/// the machine-readable [code].
class DecodeResult {
  final bool ok;
  final Map<String, Object?>? value;
  final String? code;
  final String? error;

  const DecodeResult.ok(this.value)
      : ok = true,
        code = null,
        error = null;

  const DecodeResult.fail(this.code, this.error)
      : ok = false,
        value = null;
}

const int _maxSafeInteger = 9007199254740991;

bool _isSafeInteger(Object? value) {
  if (value is int) return value.abs() <= _maxSafeInteger;
  if (value is double) {
    return value.isFinite &&
        value == value.truncateToDouble() &&
        value.abs() <= _maxSafeInteger;
  }
  return false;
}

bool _isPositiveSafeInteger(Object? value) =>
    _isSafeInteger(value) && (value as num) >= 1;

bool _isNonNegativeSafeInteger(Object? value) =>
    _isSafeInteger(value) && (value as num) >= 0;

String? _nonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

bool _isOptionalString(Map<String, Object?> message, String key) =>
    !message.containsKey(key) || message[key] is String;

/// Decodes one JSON object, reporting malformed input as a result, never a throw.
DecodeResult decode(String text) {
  Object? parsed;
  try {
    parsed = jsonDecode(text);
  } catch (_) {
    return const DecodeResult.fail('malformed-json', 'malformed JSON');
  }
  if (parsed is! Map) {
    return const DecodeResult.fail('not-an-object', 'message must be a JSON object');
  }
  final message = parsed.cast<String, Object?>();
  if (message['protocolVersion'] != protocolVersion) {
    return DecodeResult.fail(
      'bad-version',
      'unsupported protocolVersion: ${message['protocolVersion']}',
    );
  }
  switch (message['type']) {
    case 'hello':
      final hasTicket = message.containsKey('ticket');
      final hasToken = message.containsKey('token');
      if (hasTicket == hasToken) {
        return const DecodeResult.fail(
          'bad-credential',
          'hello must carry exactly one of ticket or token',
        );
      }
      final credential = hasTicket ? message['ticket'] : message['token'];
      if (credential is! String || credential.isEmpty) {
        return const DecodeResult.fail(
          'bad-credential',
          'hello credential must be a non-empty string',
        );
      }
      return DecodeResult.ok(message);
    case 'event':
      final payload = message['payload'];
      if (payload is! Map) {
        return const DecodeResult.fail('bad-payload', 'event payload must be a JSON object');
      }
      final body = payload.cast<String, Object?>();
      final kind = body['kind'];
      if (kind == 'stream') {
        if (!_isPositiveSafeInteger(body['seq'])) {
          return const DecodeResult.fail(
            'bad-seq',
            'stream seq must be a positive safe integer',
          );
        }
        if (body.containsKey('text') && body['text'] is! String) {
          return const DecodeResult.fail('bad-text', 'stream text must be a string');
        }
        if (body.containsKey('phase') && !streamPhases.contains(body['phase'])) {
          return DecodeResult.fail(
            'bad-payload',
            'stream phase must be one of ${streamPhases.join(', ')}',
          );
        }
        if (!body.containsKey('text') && !body.containsKey('phase')) {
          return const DecodeResult.fail(
            'bad-text',
            'stream frame must carry text and/or a phase',
          );
        }
        return DecodeResult.ok(message);
      }
      if (kind == 'agent') {
        if (!agentStates.contains(body['state'])) {
          return const DecodeResult.fail(
            'bad-state',
            'agent state must be idle, running or settled',
          );
        }
        return DecodeResult.ok(message);
      }
      // `message`/`tool`/`status`/`usage` are bridge-owned shapes the hub only
      // relays.
      if (kind == 'settled') {
        if (body['text'] is! String) {
          return const DecodeResult.fail('bad-text', 'settled text must be a string');
        }
        if (body['truncated'] is! bool) {
          return const DecodeResult.fail(
            'bad-field',
            'settled truncated must be a boolean',
          );
        }
        return DecodeResult.ok(message);
      }
      if (kind == 'message' || kind == 'tool' || kind == 'status' || kind == 'usage') {
        return DecodeResult.ok(message);
      }
      return DecodeResult.fail(
        'bad-payload',
        'unknown event payload kind: ${body['kind']}',
      );
    case 'register':
      if (_nonEmptyString(message['sessionId']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'register sessionId must be a non-empty string',
        );
      }
      for (final field in const [
        'sessionFile',
        'cwd',
        'name',
        'model',
        'thinkingLevel',
        'mode',
      ]) {
        if (!_isOptionalString(message, field)) {
          return DecodeResult.fail('bad-field', 'register $field must be a string');
        }
      }
      if (message.containsKey('pid') && !_isSafeInteger(message['pid'])) {
        return const DecodeResult.fail('bad-field', 'register pid must be a safe integer');
      }
      return DecodeResult.ok(message);
    case 'history':
      if (_nonEmptyString(message['sessionId']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'history sessionId must be a non-empty string',
        );
      }
      if (message['entries'] is! List) {
        return const DecodeResult.fail('bad-field', 'history entries must be an array');
      }
      if (message['truncated'] is! bool) {
        return const DecodeResult.fail('bad-field', 'history truncated must be a boolean');
      }
      return DecodeResult.ok(message);
    case 'command-result':
      if (_nonEmptyString(message['id']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'command-result id must be a non-empty string',
        );
      }
      if (message['ok'] is! bool) {
        return const DecodeResult.fail('bad-field', 'command-result ok must be a boolean');
      }
      if (!_isOptionalString(message, 'error')) {
        return const DecodeResult.fail('bad-field', 'command-result error must be a string');
      }
      return DecodeResult.ok(message);
    case 'subscribe':
      if (_nonEmptyString(message['sessionId']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'subscribe sessionId must be a non-empty string',
        );
      }
      return DecodeResult.ok(message);
    case 'unsubscribe':
      if (_nonEmptyString(message['sessionId']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'unsubscribe sessionId must be a non-empty string',
        );
      }
      return DecodeResult.ok(message);
    case 'history-request':
      if (_nonEmptyString(message['sessionId']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'history-request sessionId must be a non-empty string',
        );
      }
      if (message.containsKey('sinceSeq') && !_isPositiveSafeInteger(message['sinceSeq'])) {
        return const DecodeResult.fail(
          'bad-seq',
          'history-request sinceSeq must be a positive safe integer',
        );
      }
      return DecodeResult.ok(message);
    case 'command':
      if (_nonEmptyString(message['id']) == null ||
          _nonEmptyString(message['sessionId']) == null ||
          _nonEmptyString(message['name']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'command requires id, sessionId and name strings',
        );
      }
      return DecodeResult.ok(message);
    case 'start-session':
      if (_nonEmptyString(message['id']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'start-session id must be a non-empty string',
        );
      }
      if (message.containsKey('cwd') && _nonEmptyString(message['cwd']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'start-session cwd must be a non-empty string',
        );
      }
      if (message.containsKey('trust') && message['trust'] is! bool) {
        return const DecodeResult.fail(
          'bad-field',
          'start-session trust must be a boolean',
        );
      }
      return DecodeResult.ok(message);
    case 'list-dirs':
      if (_nonEmptyString(message['id']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'list-dirs id must be a non-empty string',
        );
      }
      if (message.containsKey('path') && _nonEmptyString(message['path']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'list-dirs path must be a non-empty string',
        );
      }
      return DecodeResult.ok(message);
    case 'dir-listing':
      if (_nonEmptyString(message['id']) == null ||
          _nonEmptyString(message['path']) == null ||
          _nonEmptyString(message['root']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'dir-listing requires id, path and root strings',
        );
      }
      if (!message.containsKey('trust') ||
          (message['trust'] != null && message['trust'] is! bool)) {
        return const DecodeResult.fail(
          'bad-field',
          'dir-listing trust must be null or a boolean',
        );
      }
      if (message['trustRequired'] is! bool) {
        return const DecodeResult.fail(
          'bad-field',
          'dir-listing trustRequired must be a boolean',
        );
      }
      final entries = message['entries'];
      if (entries is! List || entries.any((entry) => _nonEmptyString(entry) == null)) {
        return const DecodeResult.fail(
          'bad-field',
          'dir-listing entries must be non-empty strings',
        );
      }
      if (message['truncated'] is! bool) {
        return const DecodeResult.fail(
          'bad-field',
          'dir-listing truncated must be a boolean',
        );
      }
      return DecodeResult.ok(message);
    case 'kill-session':
      if (_nonEmptyString(message['id']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'kill-session id must be a non-empty string',
        );
      }
      if (_nonEmptyString(message['sessionId']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'kill-session sessionId must be a non-empty string',
        );
      }
      return DecodeResult.ok(message);
    case 'paired':
      if (_nonEmptyString(message['token']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'paired token must be a non-empty string',
        );
      }
      return DecodeResult.ok(message);
    case 'sessions':
      final sessions = message['sessions'];
      if (sessions is! List) {
        return const DecodeResult.fail('bad-field', 'sessions must be an array');
      }
      for (final entry in sessions) {
        if (entry is! Map) {
          return const DecodeResult.fail(
            'bad-field',
            'sessions entries must be JSON objects',
          );
        }
        final summary = entry.cast<String, Object?>();
        if (_nonEmptyString(summary['sessionId']) == null) {
          return const DecodeResult.fail(
            'bad-field',
            'sessions sessionId must be a non-empty string',
          );
        }
        if (_nonEmptyString(summary['label']) == null) {
          return const DecodeResult.fail(
            'bad-field',
            'sessions label must be a non-empty string',
          );
        }
        if (!agentStates.contains(summary['agentState'])) {
          return const DecodeResult.fail(
            'bad-state',
            'sessions agentState must be idle, running or settled',
          );
        }
        if (summary.containsKey('origin') &&
            !sessionOrigins.contains(summary['origin'])) {
          return const DecodeResult.fail(
            'bad-field',
            'sessions origin must be app or pc',
          );
        }
      }
      final capabilities = message['capabilities'];
      if (message.containsKey('capabilities') &&
          (capabilities is! List ||
              capabilities.any((capability) => _nonEmptyString(capability) == null))) {
        return const DecodeResult.fail(
          'bad-field',
          'sessions capabilities must be non-empty strings',
        );
      }
      return DecodeResult.ok(message);
    case 'snapshot':
      if (_nonEmptyString(message['sessionId']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'snapshot sessionId must be a non-empty string',
        );
      }
      if (!_isNonNegativeSafeInteger(message['lastSeq'])) {
        return const DecodeResult.fail(
          'bad-field',
          'snapshot lastSeq must be a non-negative safe integer',
        );
      }
      if (!agentStates.contains(message['agentState'])) {
        return const DecodeResult.fail(
          'bad-state',
          'snapshot agentState must be idle, running or settled',
        );
      }
      if (message['entries'] is! List) {
        return const DecodeResult.fail('bad-field', 'snapshot entries must be an array');
      }
      if (message['truncated'] is! bool) {
        return const DecodeResult.fail('bad-field', 'snapshot truncated must be a boolean');
      }
      return DecodeResult.ok(message);
    case 'resync-required':
      if (_nonEmptyString(message['sessionId']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'resync-required sessionId must be a non-empty string',
        );
      }
      if (_nonEmptyString(message['reason']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'resync-required reason must be a non-empty string',
        );
      }
      return DecodeResult.ok(message);
    case 'session-gone':
      if (_nonEmptyString(message['sessionId']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'session-gone sessionId must be a non-empty string',
        );
      }
      return DecodeResult.ok(message);
    case 'agent-settled':
      if (_nonEmptyString(message['sessionId']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'agent-settled sessionId must be a non-empty string',
        );
      }
      if (_nonEmptyString(message['label']) == null) {
        return const DecodeResult.fail(
          'bad-field',
          'agent-settled label must be a non-empty string',
        );
      }
      if (message['text'] is! String) {
        return const DecodeResult.fail('bad-field', 'agent-settled text must be a string');
      }
      if (message['truncated'] is! bool) {
        return const DecodeResult.fail(
          'bad-field',
          'agent-settled truncated must be a boolean',
        );
      }
      return DecodeResult.ok(message);
    default:
      return DecodeResult.fail(
        'unknown-type',
        'unknown message type: ${message['type']}',
      );
  }
}

/// Encodes exactly one JSON object per call. Trusts the map it is given.
String encode(Map<String, Object?> message) => jsonEncode(message);
