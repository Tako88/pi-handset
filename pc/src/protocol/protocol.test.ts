import assert from 'node:assert/strict';
import { test } from 'node:test';

// Deliberately `.ts`, and deliberately written before `./protocol.ts` exists:
// the red run must fail with an unresolved import, not a loader error.
import {
  PROTOCOL_VERSION,
  decode,
  encode,
  isAgentMessageType,
  isViewerMessageType,
} from './protocol.ts';
import type {
  DecodeErrorCode,
  EventMessage,
  HelloMessage,
  SessionsMessage,
} from './protocol.ts';

function expectReject(raw: string, code: DecodeErrorCode, errorPattern: RegExp): void {
  const result = decode(raw);
  if (result.ok) assert.fail(`expected rejection, got ok:true for ${raw}`);
  assert.equal(result.code, code);
  assert.match(result.error, errorPattern);
}

test('a ticket hello round-trips through encode and decode', () => {
  const hello: HelloMessage = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'hello',
    ticket: 'ABCD2345',
  };
  assert.deepEqual(decode(encode(hello)), { ok: true, value: hello });
});

test('a token hello round-trips through encode and decode', () => {
  const hello: HelloMessage = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'hello',
    token: 'a'.repeat(64),
  };
  assert.deepEqual(decode(encode(hello)), { ok: true, value: hello });
});

test('an event carrying a stream payload round-trips through encode and decode', () => {
  const event: EventMessage = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 1, text: 'hello' },
  };
  assert.deepEqual(decode(encode(event)), { ok: true, value: event });
});

test('decode accepts an empty stream delta', () => {
  const raw = JSON.stringify({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 1, text: '' },
  });
  const result = decode(raw);
  if (!result.ok) assert.fail('expected an empty string delta to be accepted');
  assert.deepEqual(result.value, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 1, text: '' },
  });
});

test('decode accepts a phase-only stream frame carrying no text', () => {
  const raw = JSON.stringify({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 3, phase: 'thinking' },
  });
  const result = decode(raw);
  if (!result.ok) assert.fail(`expected a phase-only stream to decode: ${result.error}`);
  assert.deepEqual(result.value, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 3, phase: 'thinking' },
  });
});

test('decode rejects an unknown stream phase', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq: 1, phase: 'yearning' },
    }),
    'bad-payload',
    /phase/i,
  );
});

test('decode rejects a hello carrying no credential', () => {
  expectReject(
    JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'hello' }),
    'bad-credential',
    /credential|ticket|token/i,
  );
});

test('decode rejects a hello carrying both a ticket and a token', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'hello',
      ticket: 'ABCD2345',
      token: 'a'.repeat(64),
    }),
    'bad-credential',
    /credential|ticket|token/i,
  );
});

test('decode rejects a hello whose ticket is not a string', () => {
  expectReject(
    JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'hello', ticket: 42 }),
    'bad-credential',
    /credential|ticket|token/i,
  );
});

test('decode rejects a hello whose token is null', () => {
  expectReject(
    JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: null }),
    'bad-credential',
    /credential|ticket|token/i,
  );
});

test('decode rejects a hello whose ticket is the empty string', () => {
  expectReject(
    JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'hello', ticket: '' }),
    'bad-credential',
    /credential|ticket|token/i,
  );
});

test('decode rejects a negative stream seq', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq: -1, text: 'hi' },
    }),
    'bad-seq',
    /seq/i,
  );
});

test('decode rejects a zero stream seq', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq: 0, text: 'hi' },
    }),
    'bad-seq',
    /seq/i,
  );
});

test('decode rejects a fractional stream seq', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq: 1.5, text: 'hi' },
    }),
    'bad-seq',
    /seq/i,
  );
});

test('decode rejects an unsafe-integer stream seq', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq: 9007199254740993, text: 'hi' },
    }),
    'bad-seq',
    /seq/i,
  );
});

test('decode rejects a string stream seq', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq: '1', text: 'hi' },
    }),
    'bad-seq',
    /seq/i,
  );
});

test('decode rejects a null stream seq', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq: null, text: 'hi' },
    }),
    'bad-seq',
    /seq/i,
  );
});

test('decode rejects a missing stream seq', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', text: 'hi' },
    }),
    'bad-seq',
    /seq/i,
  );
});

test('decode rejects a non-string stream text', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq: 1, text: 42 },
    }),
    'bad-text',
    /text/i,
  );
});

test('decode rejects a null stream text', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq: 1, text: null },
    }),
    'bad-text',
    /text/i,
  );
});

test('decode rejects a missing stream text', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq: 1 },
    }),
    'bad-text',
    /text/i,
  );
});

test('decode rejects an unknown event payload kind', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'nope' },
    }),
    'bad-payload',
    /payload/i,
  );
});

test('a message payload round-trips and is accepted whole', () => {
  const event = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'message', role: 'assistant', content: 'hi' },
  };
  assert.deepEqual(decode(JSON.stringify(event)), { ok: true, value: event });
});

test('a tool payload round-trips and is accepted whole', () => {
  const event = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'tool', name: 'read', status: 'running' },
  };
  assert.deepEqual(decode(JSON.stringify(event)), { ok: true, value: event });
});

test('a usage payload round-trips, including unknown tokens', () => {
  const event = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'usage', tokens: 23400, contextWindow: 128000 },
  };
  assert.deepEqual(decode(JSON.stringify(event)), { ok: true, value: event });

  // After a compaction pi reports the count as unknown until the next response,
  // so a null token count is a real wire value, not an omission.
  const unknown = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'usage', tokens: null, contextWindow: 128000 },
  };
  assert.deepEqual(decode(JSON.stringify(unknown)), { ok: true, value: unknown });
});

test('a status payload round-trips and is accepted whole', () => {
  const event = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'status', message: 'compacting' },
  };
  assert.deepEqual(decode(JSON.stringify(event)), { ok: true, value: event });
});

test('an agent payload with a known state round-trips', () => {
  const event = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'agent', state: 'settled' },
  };
  assert.deepEqual(decode(JSON.stringify(event)), { ok: true, value: event });
});

test('decode rejects an agent payload with an unknown state', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'agent', state: 'sleeping' },
    }),
    'bad-state',
    /state/i,
  );
});

test('a sessions message round-trips through encode and decode', () => {
  const sessions: SessionsMessage = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'sessions',
    sessions: [{ sessionId: 'sess-1', label: 'my session', agentState: 'settled' }],
  };
  assert.deepEqual(decode(encode(sessions)), { ok: true, value: sessions });
});

test('a decoded sessions summary carries no lastSeq watermark', () => {
  const raw = JSON.stringify({
    protocolVersion: PROTOCOL_VERSION,
    type: 'sessions',
    sessions: [{ sessionId: 'sess-1', label: 'my session', agentState: 'settled' }],
  });
  const result = decode(raw);
  if (!result.ok) assert.fail('sessions must decode');
  if (result.value.type !== 'sessions') assert.fail('expected a sessions message');
  assert.deepEqual(Object.keys(result.value.sessions[0]).sort(), [
    'agentState',
    'label',
    'sessionId',
  ]);
});

test('decode accepts an empty sessions list', () => {
  const raw = JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'sessions', sessions: [] });
  assert.deepEqual(decode(raw), {
    ok: true,
    value: { protocolVersion: PROTOCOL_VERSION, type: 'sessions', sessions: [] },
  });
});

test('decode rejects a sessions message whose sessions is not an array', () => {
  expectReject(
    JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'sessions', sessions: 'nope' }),
    'bad-field',
    /sessions/i,
  );
});

test('decode rejects a sessions entry that is not an object', () => {
  expectReject(
    JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'sessions', sessions: [42] }),
    'bad-field',
    /entr|object/i,
  );
});

test('decode rejects a sessions entry with a missing sessionId', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'sessions',
      sessions: [{ label: 'one', agentState: 'idle' }],
    }),
    'bad-field',
    /sessionId/i,
  );
});

test('decode rejects a sessions entry with an empty sessionId', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'sessions',
      sessions: [{ sessionId: '', label: 'one', agentState: 'idle' }],
    }),
    'bad-field',
    /sessionId/i,
  );
});

test('decode rejects a sessions entry with a non-string label', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'sessions',
      sessions: [{ sessionId: 'sess-1', label: 42, agentState: 'idle' }],
    }),
    'bad-field',
    /label/i,
  );
});

test('decode rejects a sessions entry with an unknown agent state', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'sessions',
      sessions: [{ sessionId: 'sess-1', label: 'one', agentState: 'done' }],
    }),
    'bad-state',
    /state/i,
  );
});

test('decode accepts a minimal start-session', () => {
  const raw = JSON.stringify({
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 'start-1',
  });
  const result = decode(raw);
  if (!result.ok) assert.fail(`expected a start-session to decode: ${result.error}`);
  assert.deepEqual(result.value, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 'start-1',
  });
});

test('decode accepts a minimal kill-session', () => {
  const raw = JSON.stringify({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'kill-1',
    sessionId: 'sess-1',
  });
  const result = decode(raw);
  if (!result.ok) assert.fail(`expected a kill-session to decode: ${result.error}`);
  assert.deepEqual(result.value, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'kill-1',
    sessionId: 'sess-1',
  });
});

test('start-session and kill-session are viewer message types', () => {
  assert.equal(isViewerMessageType('start-session'), true);
  assert.equal(isViewerMessageType('kill-session'), true);
  assert.equal(isAgentMessageType('start-session'), false);
  assert.equal(isAgentMessageType('kill-session'), false);
});

test('decode rejects a start-session with a missing id', () => {
  expectReject(
    JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'start-session' }),
    'bad-field',
    /id/i,
  );
});

test('decode rejects a start-session with an empty id', () => {
  expectReject(
    JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: '' }),
    'bad-field',
    /id/i,
  );
});

test('decode rejects a kill-session with a missing sessionId', () => {
  expectReject(
    JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'kill-session', id: 'k1' }),
    'bad-field',
    /sessionId/i,
  );
});

test('decode rejects a kill-session with an empty sessionId', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'kill-session',
      id: 'k1',
      sessionId: '',
    }),
    'bad-field',
    /sessionId/i,
  );
});

test('decode accepts a sessions entry with an app origin', () => {
  const raw = JSON.stringify({
    protocolVersion: PROTOCOL_VERSION,
    type: 'sessions',
    sessions: [{ sessionId: 'sess-1', label: 'one', agentState: 'idle', origin: 'app' }],
  });
  const result = decode(raw);
  if (!result.ok) assert.fail(`expected an app origin to decode: ${result.error}`);
  assert.equal((result.value as SessionsMessage).sessions[0]!.origin, 'app');
});

test('decode rejects a sessions entry with an unknown origin', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'sessions',
      sessions: [{ sessionId: 'sess-1', label: 'one', agentState: 'idle', origin: 'nope' }],
    }),
    'bad-field',
    /origin/i,
  );
});

test('decode accepts a sessions entry with no origin', () => {
  const raw = JSON.stringify({
    protocolVersion: PROTOCOL_VERSION,
    type: 'sessions',
    sessions: [{ sessionId: 'sess-1', label: 'one', agentState: 'idle' }],
  });
  const result = decode(raw);
  if (!result.ok) assert.fail(`expected an absent origin to decode: ${result.error}`);
  assert.equal(
    Object.prototype.hasOwnProperty.call(result.value, 'origin'),
    false,
    'an absent origin must not be invented by the decoder',
  );
});

test('the per-listener message type guards know their own set', () => {
  assert.equal(isAgentMessageType('register'), true);
  assert.equal(isAgentMessageType('command'), false);
  assert.equal(isViewerMessageType('command'), true);
  assert.equal(isViewerMessageType('register'), false);
  assert.equal(isAgentMessageType(42), false);
});

test('decode rejects a top-level stream message', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'stream',
      seq: 1,
      text: 'hi',
    }),
    'unknown-type',
    /type/i,
  );
});

test('decode rejects an unknown protocol version', () => {
  expectReject(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION + 1,
      type: 'hello',
      ticket: 'ABCD2345',
    }),
    'bad-version',
    /protocolVersion/i,
  );
});

test('decode rejects an unknown message type', () => {
  expectReject(
    JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'nope' }),
    'unknown-type',
    /type/i,
  );
});

test('decode rejects a JSON array as not-an-object', () => {
  expectReject('[]', 'not-an-object', /object/i);
});

test('decode rejects JSON null as not-an-object', () => {
  expectReject('null', 'not-an-object', /object/i);
});

test('decode rejects a JSON primitive as not-an-object', () => {
  expectReject('42', 'not-an-object', /object/i);
});

test('encode produces exactly one JSON object per call', () => {
  const hello: HelloMessage = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'hello',
    ticket: 'ABCD2345',
  };
  const encoded = encode(hello);
  assert.equal(encoded.split('\n').length, 1);
  const parsed = JSON.parse(encoded);
  assert.equal(Array.isArray(parsed), false);
  assert.deepEqual(parsed, hello);
});

test('decode reports malformed JSON with a code instead of throwing', () => {
  expectReject('{"protocolVersion":', 'malformed-json', /json/i);
});

// V8's JSON.parse is iterative on this Node, so deep nesting does not actually
// raise RangeError here; this locks the broader "decode never throws" guarantee
// and would surface a parser regression that lets the stack blow.
test('decode never throws on deeply nested JSON', () => {
  const result = decode('['.repeat(200_000) + ']'.repeat(200_000));
  assert.equal(result.ok, false);
});

// Regression guard: `decodeOrderedStream` rejected a stale `seq`, but the
// shipping hub (`hub.ts`) accepts one with `Math.max`. The contradictory helper
// has no production caller and must not come back. Accessed dynamically so the
// test keeps compiling before and after the deletion.
test('the retired ordered-stream helper is not exported', async () => {
  const module = (await import('./protocol.ts')) as Record<string, unknown>;
  assert.equal(module.decodeOrderedStream, undefined);
});
