/**
 * The bridge's wire codec — `parseCommand` and `encodeAgentMessage` —
 * exercised directly through `src/bridge/wire.ts`.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { decode, encode, PROTOCOL_VERSION } from '../protocol/protocol.ts';
import { encodeAgentMessage, parseCommand } from './wire.ts';

// ---------------------------------------------------------------------------
// parseCommand — rejected shapes
// ---------------------------------------------------------------------------

const validBase = { id: 'c1', sessionId: 's1', name: 'prompt' };

test('an undefined id is rejected', () => {
  assert.equal(parseCommand({ ...validBase, id: undefined }), null);
});

test('a non-string id is rejected', () => {
  assert.equal(parseCommand({ ...validBase, id: 42 }), null);
});

test('an empty id is rejected', () => {
  assert.equal(parseCommand({ ...validBase, id: '' }), null);
});

test('an undefined sessionId is rejected', () => {
  assert.equal(parseCommand({ ...validBase, sessionId: undefined }), null);
});

test('a non-string sessionId is rejected', () => {
  assert.equal(parseCommand({ ...validBase, sessionId: 42 }), null);
});

test('an empty sessionId is rejected', () => {
  assert.equal(parseCommand({ ...validBase, sessionId: '' }), null);
});

test('an undefined name is rejected', () => {
  assert.equal(parseCommand({ ...validBase, name: undefined }), null);
});

test('a non-string name is rejected', () => {
  assert.equal(parseCommand({ ...validBase, name: 42 }), null);
});

test('an empty name is rejected', () => {
  assert.equal(parseCommand({ ...validBase, name: '' }), null);
});

// ---------------------------------------------------------------------------
// parseCommand — accepted shapes
// ---------------------------------------------------------------------------

test('a valid command is stamped with the protocol version and command type', () => {
  const command = parseCommand(validBase);
  assert.ok(command);
  assert.equal(command.protocolVersion, PROTOCOL_VERSION);
  assert.equal(command.type, 'command');
  assert.equal(command.id, 'c1');
  assert.equal(command.sessionId, 's1');
  assert.equal(command.name, 'prompt');
});

test('args pass through unchanged when present', () => {
  const args = { text: 'hi' };
  const command = parseCommand({ ...validBase, args });
  assert.ok(command);
  assert.deepEqual(command.args, { text: 'hi' });
});

test('args is absent from the command when the frame omits it', () => {
  const command = parseCommand(validBase);
  assert.ok(command);
  assert.equal('args' in command, false);
});

test('an explicit undefined args is preserved by key presence', () => {
  const command = parseCommand({ ...validBase, args: undefined });
  assert.ok(command);
  assert.equal('args' in command, true);
  assert.equal(command.args, undefined);
});

// ---------------------------------------------------------------------------
// encodeAgentMessage
// ---------------------------------------------------------------------------

test('a hello frame round-trips through the protocol encoder', () => {
  const hello = { protocolVersion: PROTOCOL_VERSION, type: 'hello' as const, token: 't' };
  assert.equal(encodeAgentMessage(hello), encode(hello));
  const decoded = decode(encodeAgentMessage(hello));
  assert.ok(decoded.ok);
  assert.deepEqual(decoded.value, hello);
});

test('an event frame round-trips through the protocol encoder', () => {
  const event = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event' as const,
    payload: { kind: 'stream' as const, seq: 1, text: 'x' },
  };
  assert.equal(encodeAgentMessage(event), encode(event));
  const decoded = decode(encodeAgentMessage(event));
  assert.ok(decoded.ok);
  assert.deepEqual(decoded.value, event);
});

test('a register frame is JSON-encoded', () => {
  const register = { protocolVersion: PROTOCOL_VERSION, type: 'register' as const, sessionId: 's1' };
  assert.equal(encodeAgentMessage(register), JSON.stringify(register));
  assert.deepEqual(JSON.parse(encodeAgentMessage(register)), register);
});

test('a history frame is JSON-encoded', () => {
  const history = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'history' as const,
    sessionId: 's1',
    entries: [{ a: 1 }],
    truncated: false,
  };
  assert.equal(encodeAgentMessage(history), JSON.stringify(history));
  assert.deepEqual(JSON.parse(encodeAgentMessage(history)), history);
});

test('a command-result frame is JSON-encoded', () => {
  const result = { protocolVersion: PROTOCOL_VERSION, type: 'command-result' as const, id: 'c1', ok: true };
  assert.equal(encodeAgentMessage(result), JSON.stringify(result));
  assert.deepEqual(JSON.parse(encodeAgentMessage(result)), result);
});
