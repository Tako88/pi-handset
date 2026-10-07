/**
 * Reconnect backoff, exercised through `src/bridge/backoff.ts`.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { CLOSE_CAPABILITY, CLOSE_INTERNAL, CLOSE_PROTOCOL, CLOSE_RATE_LIMITED } from '../protocol/protocol.ts';
import { computeBackoff, RATE_LIMITED_RECONNECT_MS } from './backoff.ts';
import { makeHarness, parsed } from '../../test/support/bridge-harness.ts';

// ---------------------------------------------------------------------------
// Reconnect backoff
// ---------------------------------------------------------------------------

test('backoff never exceeds its cap across many attempts', () => {
  for (let attempt = 0; attempt <= 1000; attempt += 1) {
    const delay = computeBackoff(attempt, { rng: () => 1 });
    assert.ok(delay <= 30_000, `attempt ${attempt} yielded ${delay}`);
  }
});

test('backoff jitters between calls at the same attempt', () => {
  const low = computeBackoff(4, { rng: () => 0.1 });
  const high = computeBackoff(4, { rng: () => 0.9 });
  assert.notEqual(low, high);
});

test('a 4003 capability close does not schedule a reconnect', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  socket.drop(CLOSE_CAPABILITY);
  assert.equal(harness.timers.length, 0, 'a bridge capability bug must not retry forever');
});

test('a 4002 protocol close does not schedule a reconnect', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  socket.drop(CLOSE_PROTOCOL);
  assert.equal(harness.timers.length, 0, 'a protocol violation is permanent; retrying cannot fix it');
});

test('a 4002 close is surfaced as terminal', () => {
  const harness = makeHarness({ env: { PI_HANDSET_DEBUG: '1' } });
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  socket.drop(CLOSE_PROTOCOL);
  assert.ok(
    harness.writes.some((w) => w.stream === 'stderr' && w.text.includes('protocol close 4002')),
    'the operator must see why the bridge stopped',
  );
});

// PIN (green at red-first time — the fall-through already reconnects): the
// M2×M3 collision guard. A contained internal error (CLOSE_INTERNAL, 4500) is
// transient and MUST still reconnect. A future edit that made every >=4000 code
// terminal would redden this before it shipped permanent bridge death.
test('a 4500 internal close still reconnects', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  socket.drop(CLOSE_INTERNAL);
  assert.equal(harness.timers.length, 1, 'a contained internal fault is transient; retry');
});

test('a 4008 rate-limit close reconnects after a fixed longer delay', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  socket.drop(CLOSE_RATE_LIMITED);
  assert.equal(harness.timers.length, 1);
  assert.equal(harness.timers[0].ms, RATE_LIMITED_RECONNECT_MS);
  assert.ok(RATE_LIMITED_RECONNECT_MS > 500, 'the rate-limit wait exceeds the first backoff step');
  // Fired once, the reconnect is dialled and the next 4008 waits the same
  // fixed span rather than a jittered backoff step.
  harness.fireTimer();
  const second = harness.sockets[1];
  second.open();
  second.drop(CLOSE_RATE_LIMITED);
  assert.equal(harness.timers[1].ms, RATE_LIMITED_RECONNECT_MS);
});

test('a dropped socket schedules a reconnect through the injected clock', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  assert.equal(harness.timers.length, 0);
  socket.drop();
  assert.equal(harness.timers.length, 1);
  assert.ok(harness.timers[0].ms <= 30_000);
});

test('reconnect resends hello, register and the current agent state', () => {
  const harness = makeHarness();
  harness.start();
  const first = harness.sockets[0];
  first.open();
  first.drop();
  harness.fireTimer();
  const second = harness.sockets[1];
  second.open();
  const types = parsed(second).map((m) => m.type);
  assert.deepEqual(types.slice(0, 2), ['hello', 'register']);
  assert.deepEqual(parsed(second)[2].payload, { kind: 'agent', state: 'idle' });
});
