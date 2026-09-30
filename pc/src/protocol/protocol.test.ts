import assert from 'node:assert/strict';
import { test } from 'node:test';

// Deliberately `.ts`, and deliberately written before `./protocol.ts` exists:
// the red run must fail with an unresolved import, not a loader error.
import { PROTOCOL_VERSION, decode, encode } from './protocol.ts';
import type { DecodeErrorCode, EventMessage, HelloMessage } from './protocol.ts';

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
