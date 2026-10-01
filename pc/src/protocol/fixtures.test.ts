// The shared golden fixtures at the repo root, asserted by BOTH suites.
//
// `protocol/fixtures/valid/` must decode; `protocol/fixtures/invalid/` must be
// rejected for a named machine-readable reason. `fixtures/invalid/cases.json`
// maps each invalid fixture to the code `decode` must return for it, so a
// fixture that fails for the wrong reason is itself a failure.
//
// Decoding is necessary but far from sufficient: both codecs echo their parsed
// input, so `ok:true` alone is satisfied by a stub. `valid/expectations.json`
// supplies the independently-authored decoded field values each fixture must
// produce, and the assertions below are the anti-drift mechanism M7 exists for.
//
// `event-tool.json` is envelope-only and forward-looking: the M6 bridge ignores
// every `toolcall_*` event, so no producer emits `kind:"tool"` yet. It pins the
// relay envelope until a producer exists.

import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  ALL_MESSAGE_TYPES,
  AGENT_MESSAGE_TYPES,
  EVENT_PAYLOAD_KINDS,
  HUB_TO_VIEWER_MESSAGE_TYPES,
  SESSION_ORIGINS,
  STREAM_PHASES,
  VIEWER_MESSAGE_TYPES,
  decode,
  encode,
} from './protocol.ts';
import type { DecodeResult, EventMessage } from './protocol.ts';

const validDir = fileURLToPath(new URL('../../../protocol/fixtures/valid/', import.meta.url));
const invalidDir = fileURLToPath(new URL('../../../protocol/fixtures/invalid/', import.meta.url));
const messageTypesPath = fileURLToPath(
  new URL('../../../protocol/fixtures/message-types.json', import.meta.url),
);

interface InvalidCase {
  file: string;
  code: string;
}

interface Fixture {
  file: string;
  raw: string;
}

/** `expectations.json` is metadata, not a message fixture. */
function isMessageFixture(name: string): boolean {
  return name.endsWith('.json') && name !== 'expectations.json';
}

function validFixtures(): Fixture[] {
  return readdirSync(validDir)
    .filter(isMessageFixture)
    .sort()
    .map((file) => ({ file, raw: readFileSync(validDir + file, 'utf8') }));
}

function decodeFixture(fixture: Fixture): DecodeResult {
  return decode(fixture.raw);
}

const invalidCases: InvalidCase[] = (
  JSON.parse(readFileSync(invalidDir + 'cases.json', 'utf8')) as { cases: InvalidCase[] }
).cases;

/**
 * Every field named in `expected` must be present in `actual` and equal to it.
 * Objects match as a recursive subset so an expectation pins the fields that
 * matter without restating the whole envelope; arrays match in full.
 */
function assertSubset(expected: unknown, actual: unknown, path: string): void {
  if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), `${path} must be an array, got ${typeof actual}`);
    assert.equal(actual.length, expected.length, `${path} length must match`);
    expected.forEach((item, index) => assertSubset(item, actual[index], `${path}[${index}]`));
    return;
  }
  if (expected !== null && typeof expected === 'object') {
    assert.ok(
      actual !== null && typeof actual === 'object' && !Array.isArray(actual),
      `${path} must be an object`,
    );
    for (const [key, value] of Object.entries(expected as Record<string, unknown>)) {
      assert.ok(
        Object.prototype.hasOwnProperty.call(actual, key),
        `${path}.${key} is missing from the decoded value`,
      );
      assertSubset(value, (actual as Record<string, unknown>)[key], `${path}.${key}`);
    }
    return;
  }
  assert.deepEqual(actual, expected, `${path} must equal ${JSON.stringify(expected)}`);
}

/**
 * The hand-authored expectations. Keys beginning `_` are comments, not
 * fixtures. Read at module scope on purpose: a missing or malformed file is a
 * hard failure of every test in this file.
 */
const expectationsFile = JSON.parse(
  readFileSync(validDir + 'expectations.json', 'utf8'),
) as Record<string, unknown>;
const expectationEntries: Array<[string, unknown]> = Object.entries(expectationsFile).filter(
  ([file]) => !file.startsWith('_'),
);

test('every valid fixture decodes', () => {
  for (const fixture of validFixtures()) {
    const result = decodeFixture(fixture);
    assert.equal(
      result.ok,
      true,
      `${fixture.file} must decode: ${JSON.stringify(result)}`,
    );
  }
});

test('every valid fixture decodes to its expected field values', () => {
  const byFile = new Map(expectationEntries);
  for (const fixture of validFixtures()) {
    const expected = byFile.get(fixture.file);
    assert.ok(expected !== undefined, `no expectation entry for ${fixture.file}`);
    const result = decodeFixture(fixture);
    if (!result.ok) assert.fail(`${fixture.file} must decode`);
    assertSubset(expected, result.value, fixture.file);
  }
});

test('every valid fixture has an expectation entry and every entry names a fixture', () => {
  const fixtures = new Set(validFixtures().map((fixture) => fixture.file));
  const expectations = new Set(expectationEntries.map(([file]) => file));
  for (const file of fixtures) {
    assert.ok(expectations.has(file), `no expectation entry for valid fixture: ${file}`);
  }
  for (const file of expectations) {
    assert.ok(fixtures.has(file), `expectation entry names no valid fixture: ${file}`);
  }
});

// Demoted: decode echoes its input, so this proves only that no field was
// dropped in the decode→encode round trip, never that a field was validated.
test('decode re-encodes every valid fixture without dropping or adding a field', () => {
  for (const fixture of validFixtures()) {
    const result = decodeFixture(fixture);
    if (!result.ok) assert.fail(`${fixture.file} must decode`);
    assert.deepEqual(
      JSON.parse(encode(result.value)),
      JSON.parse(fixture.raw),
      `${fixture.file} must round-trip`,
    );
  }
});

test('every message type the protocol defines has a valid fixture', () => {
  const covered = new Set<string>();
  for (const fixture of validFixtures()) {
    const result = decodeFixture(fixture);
    if (!result.ok) assert.fail(`${fixture.file} must decode`);
    covered.add(result.value.type);
  }
  for (const type of new Set(ALL_MESSAGE_TYPES)) {
    assert.ok(covered.has(type), `no valid fixture for message type: ${type}`);
  }
});

test('every event payload kind has a valid fixture', () => {
  const covered = new Set<string>();
  for (const fixture of validFixtures()) {
    const result = decodeFixture(fixture);
    if (result.ok && result.value.type === 'event') {
      covered.add((result.value as EventMessage).payload.kind);
    }
  }
  for (const kind of EVENT_PAYLOAD_KINDS) {
    assert.ok(covered.has(kind), `no valid fixture for event payload kind: ${kind}`);
  }
});

// Ties the canonical lists to `decode`'s switch. TypeScript unions are erased
// at runtime, so the lists cannot be derived from the type; this one-way check
// is what stops a type that is in a union and in `decode` but missing from a
// list from shipping green with no fixture demanded.
test('every message type in the canonical lists decodes from a minimal body', () => {
  const minimalBodies: Record<string, Record<string, unknown>> = {
    hello: { protocolVersion: 1, type: 'hello', ticket: 'ABCD2345' },
    register: { protocolVersion: 1, type: 'register', sessionId: 'sess' },
    event: {
      protocolVersion: 1,
      type: 'event',
      payload: { kind: 'stream', seq: 1, text: '' },
    },
    history: { protocolVersion: 1, type: 'history', sessionId: 'sess', entries: [], truncated: false },
    'command-result': { protocolVersion: 1, type: 'command-result', id: 'id', ok: true },
    subscribe: { protocolVersion: 1, type: 'subscribe', sessionId: 'sess' },
    unsubscribe: { protocolVersion: 1, type: 'unsubscribe', sessionId: 'sess' },
    'history-request': { protocolVersion: 1, type: 'history-request', sessionId: 'sess' },
    command: { protocolVersion: 1, type: 'command', id: 'id', sessionId: 'sess', name: 'prompt' },
    'start-session': { protocolVersion: 1, type: 'start-session', id: 'start-1' },
    'kill-session': {
      protocolVersion: 1,
      type: 'kill-session',
      id: 'kill-1',
      sessionId: 'sess',
    },
    paired: { protocolVersion: 1, type: 'paired', token: 'tok' },
    sessions: { protocolVersion: 1, type: 'sessions', sessions: [] },
    snapshot: {
      protocolVersion: 1,
      type: 'snapshot',
      sessionId: 'sess',
      lastSeq: 0,
      agentState: 'idle',
      entries: [],
      truncated: false,
    },
    'resync-required': { protocolVersion: 1, type: 'resync-required', sessionId: 'sess', reason: 'r' },
    'session-gone': { protocolVersion: 1, type: 'session-gone', sessionId: 'sess' },
  };
  for (const type of ALL_MESSAGE_TYPES) {
    const body = minimalBodies[type];
    assert.ok(body !== undefined, `no minimal body for message type: ${type}`);
    const result = decode(JSON.stringify(body));
    assert.equal(result.ok, true, `${type} must decode from its minimal body: ${JSON.stringify(result)}`);
    if (!result.ok) continue;
    assert.equal(result.value.type, type, `decoding ${type} must yield type ${type}`);
  }
});

// Cross-language pin: both suites assert their own list against this shared
// file, so a list dropped in one language fails that language's suite.
test('the canonical message-type and payload-kind lists match the shared fixture', () => {
  const shared = JSON.parse(readFileSync(messageTypesPath, 'utf8')) as {
    messageTypes: string[];
    eventPayloadKinds: string[];
    streamPhases: string[];
    agentMessageTypes: string[];
    viewerMessageTypes: string[];
    hubToViewerMessageTypes: string[];
    sessionOrigins: string[];
  };
  assert.deepEqual(new Set(ALL_MESSAGE_TYPES), new Set(shared.messageTypes));
  assert.deepEqual(new Set(EVENT_PAYLOAD_KINDS), new Set(shared.eventPayloadKinds));
  assert.deepEqual(new Set(STREAM_PHASES), new Set(shared.streamPhases));
  assert.deepEqual(new Set(AGENT_MESSAGE_TYPES), new Set(shared.agentMessageTypes));
  assert.deepEqual(new Set(VIEWER_MESSAGE_TYPES), new Set(shared.viewerMessageTypes));
  assert.deepEqual(new Set(HUB_TO_VIEWER_MESSAGE_TYPES), new Set(shared.hubToViewerMessageTypes));
  assert.deepEqual(new Set(SESSION_ORIGINS), new Set(shared.sessionOrigins));
});

test('every invalid fixture is rejected for the right reason', () => {
  assert.ok(invalidCases.length > 0, 'cases.json must name at least one case');
  for (const invalid of invalidCases) {
    const raw = readFileSync(invalidDir + invalid.file, 'utf8');
    const result = decode(raw);
    assert.equal(result.ok, false, `${invalid.file} must be rejected`);
    if (result.ok) assert.fail(`${invalid.file} must be rejected`);
    assert.equal(
      result.code,
      invalid.code,
      `${invalid.file} must be rejected as ${invalid.code}, got ${result.code}`,
    );
  }
});

test('every invalid fixture is named in cases.json and vice versa', () => {
  const files = readdirSync(invalidDir)
    .filter((name) => name !== 'cases.json')
    .sort();
  const named = invalidCases.map((invalid) => invalid.file).sort();
  assert.deepEqual(
    files,
    named,
    'invalid/ must contain exactly the fixtures cases.json names (plus cases.json)',
  );
});
