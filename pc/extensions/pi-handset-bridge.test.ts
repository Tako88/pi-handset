// command dispatch: model, thinking, compaction, history, usage, commands and registry.
// Split from the bridge test file; test blocks are byte-exact.
//
// Preserved from the original bridge test file:
//
/**
 * The pi bridge extension, driven against a stub `ExtensionAPI` and a fake
 * socket. Nothing here dials: the socket factory is injected, the clock is
 * injected, the RNG is injected, and the debug sink is injected.
 *
 * This is the entry remainder — the Bridge class itself: lifecycle, command
 * dispatch, registration and labels, transport and endpoint discovery, and the
 * live wiring that needs a whole bridge instance. The pure-logic tests live
 * beside the module they exercise under `src/bridge/`, sharing the fakes in
 * `test/support/bridge-harness.ts`.
 *
 * The tests here are grouped by behaviour:
 * - agent state is terminal on `agent_settled`, never on `agent_end`
 * - the command allowlist dispatches, everything else is refused
 * - mode guard, silence, and lifecycle
 * - session labels, replacement, and session control
 * - live wiring, argument retention, and history replay
 */
//
// ---------------------------------------------------------------------------
// Command dispatch
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { test, beforeEach } from 'node:test';
import { PROTOCOL_VERSION } from '../src/protocol/protocol.ts';
import type { BridgeModel } from '../src/bridge/pi-types.ts';
import { resetSessionLinkageForTests } from './pi-handset-bridge.ts';
import { makeHarness, parsed, sendCommand } from '../test/support/bridge-harness.ts';

beforeEach(() => resetSessionLinkageForTests());

test('abort aborts the active operation and acknowledges dispatch', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'abort');
  assert.equal(ctx.aborts(), 1);
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-abort',
    ok: true,
  });
});

test('setModel resolves the reference through the registry before calling pi', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  // The resolved registry OBJECT, not the `{provider, id}` reference: pi's
  // setModel needs the full Model, and passing the reference would be a
  // type-lie pi cannot use.
  assert.deepEqual(harness.pi.models, [
    { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  ]);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
});

test('setModel reports a rejected model as a failed command-result', async () => {
  const harness = makeHarness();
  harness.pi.modelAccepted = false;
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // The wrapper's `false` path (a stale auth snapshot), distinct from the
  // unknown-id `'model not found'` and the no-registry `'models unavailable'`.
  assert.equal(result.error, 'model not accepted');
});

test('setModel refuses an unknown model without calling pi', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { provider: 'test-provider', id: 'nope' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'model not found');
  assert.deepEqual(harness.pi.models, [], 'pi.setModel must not be called for an unknown model');
});

test('setModel without a provider or id is refused', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { id: 'test-model' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'missing model');
  assert.deepEqual(harness.pi.models, []);
});

test('setModel without a registry is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.removeRegistry();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { provider: 'test-provider', id: 'test-model' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'models unavailable');
  assert.deepEqual(harness.pi.models, []);
});

test('setModel is refused mid-turn, before calling pi', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { provider: 'test-provider', id: 'test-model' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'cannot switch the model while pi is working');
  // pi's own AgentSession.setModel has no streaming guard; the bridge refuses
  // before the switch so the session cannot end up on a mixed-model turn.
  assert.deepEqual(harness.pi.models, [], 'pi.setModel must not be called mid-turn');
});

test('a throwing pi.setModel surfaces the thrown message, not the accepted boolean', async () => {
  const harness = makeHarness();
  harness.pi.modelError = new Error('No API key for test-provider/test-model');
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // A stale auth snapshot makes pi's inner setModel THROW; the message must
  // survive rather than be replaced by the wrapper's `'model not accepted'`.
  assert.equal(result.error, 'No API key for test-provider/test-model');
});

test('an accepted same-model switch still re-reports usage exactly once', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  // `_emitModelSelect` early-returns for an equal model, so the direct
  // `sendUsageEvent` is the only frame and must not be dropped.
  // The exact count pins StubPi's behaviour (its `setModel` never emits
  // `model_select`), not a wire guarantee: real pi also emits the event, which
  // the bridge documents as a harmless idempotent duplicate. If the stub grows
  // faithful, relax the count to >= 1 — do not "fix" the bridge.
  const usage = parsed(socket)
    .slice(before)
    .filter((message) => (message.payload as { kind?: string } | undefined)?.kind === 'usage');
  assert.equal(usage.length, 1);
});

test('setThinkingLevel dispatches the level', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'setThinkingLevel', { level: 'high' });
  assert.deepEqual(harness.pi.thinkingLevels, ['high']);
});

test('compact requests compaction', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'compact');
  assert.equal(ctx.compacts(), 1);
});

test('fetchHistory replies with a history message', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'fetchHistory');
  const history = parsed(socket).find((m) => m.type === 'history')!;
  assert.deepEqual(history.entries, [{ type: 'message', id: 'e1' }]);
  assert.equal(history.truncated, false);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
});

test('a history-request replays history and then the context usage', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  const after = parsed(socket).slice(-2);
  assert.equal(after[0].type, 'history');
  // A phone that attaches mid-session must see a number without waiting for a
  // turn, and the hub only relays to subscribers — which is why this rides the
  // reply rather than the register frame.
  assert.deepEqual(after[1], {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: {
      kind: 'usage',
      tokens: 23400,
      contextWindow: 128000,
      thinkingLevel: 'medium',
      model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
    },
  });
});

test('an unknown token count travels as null', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setUsage({ tokens: null, contextWindow: 128000 });
  const socket = harness.sockets[0];
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: null,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('agent_settled reports the terminal state and then the usage', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(
    emitted.map((m) => (m.payload as { kind?: string }).kind),
    ['agent', 'usage', 'settled'],
  );
});

test('a compaction reports unknown tokens', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  ctx.setUsage({ tokens: null, contextWindow: 128000 });
  harness.pi.handlers.get('session_compact')!({}, ctx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual((emitted.at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: null,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('a context without a thinking level omits the field', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete ctx.thinkingLevel;
  const socket = harness.sockets[0];
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  // The key must be absent, not `null`: an older pi exposes no level and the
  // field is optional.
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('a context without a model omits the field', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete ctx.model;
  const socket = harness.sockets[0];
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  // The key must be absent, not `null`: an older pi exposes no model and the
  // field is optional.
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
  });
});

test('a malformed model is omitted, never sent half-formed', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // `name` missing: the projection must drop the whole entry rather than emit a
  // `ModelSummary` the protocol validator would reject.
  ctx.model = { id: 'test-model', provider: 'test-provider' } as unknown as BridgeModel;
  const socket = harness.sockets[0];
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
  });
});

test('a model_select re-reports usage', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  ctx.model = { id: 'm2', provider: 'test-provider', name: 'Second Model' };
  harness.pi.handlers.get('model_select')!(
    { model: ctx.model, previousModel: undefined, source: 'select' },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'm2', name: 'Second Model' },
  });
});

test('a thinking level change re-reports usage', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  ctx.thinkingLevel = 'low';
  harness.pi.handlers.get('thinking_level_select')!(
    { level: 'low', previousLevel: 'medium' },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'low',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('the reported thinking level is read live, not cached', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  ctx.thinkingLevel = 'high';
  const before = socket.sent.length;
  harness.pi.handlers.get('thinking_level_select')!(
    { level: 'high', previousLevel: 'low' },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'high',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('a failed compaction reaches the transcript as an error notice', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!(
    { reason: 'manual', errorMessage: 'Compaction failed: no model', aborted: false },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'status',
    event: 'error',
    message: 'Compaction failed: no model',
  });
});

test('an overflow compaction failure also reaches the transcript', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!(
    {
      reason: 'overflow',
      errorMessage: 'Context overflow recovery failed: too large',
      aborted: false,
    },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'status',
    event: 'error',
    message: 'Context overflow recovery failed: too large',
  });
});

test('an aborted compaction clears the announcement without an error notice', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!({ reason: 'manual', aborted: true }, ctx);
  // The announcement must still be cleared — an aborted compaction is over just
  // like a failed one — but nothing is shown, because nothing went wrong.
  assert.deepEqual(parsed(socket).slice(before).map((m) => (m as { payload: unknown }).payload), [
    { kind: 'status', event: 'compacting', active: false },
  ]);
});

test('a compaction start announces itself to the app', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_before_compact')!(
    { type: 'session_before_compact', reason: 'manual', willRetry: false },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'status',
    event: 'compacting',
    active: true,
  });
});

test('the compaction start handler neither cancels nor customises the compaction', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  harness.sockets[0].open();
  // pi awaits this handler and reads the result: a truthy `cancel` aborts the
  // compaction and a `compaction` replaces the summary. Returning undefined is
  // what keeps the bridge from silently changing what compaction does.
  const result = harness.pi.handlers.get('session_before_compact')!(
    { type: 'session_before_compact', reason: 'threshold', willRetry: true },
    ctx,
  );
  assert.equal(result, undefined);
});

test('a completed compaction clears the announcement', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact')!({ type: 'session_compact', reason: 'manual' }, ctx);
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .map((m) => (m as { payload: { kind: string; event?: string } }).payload)
      .filter((p) => p.kind === 'status'),
    [{ kind: 'status', event: 'compacting', active: false }],
  );
});

test('a failed compaction clears the announcement before the error notice', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!(
    { reason: 'overflow', errorMessage: 'Context overflow recovery failed', aborted: false },
    ctx,
  );
  // Order matters: the indicator is cleared first, so the app cannot end up
  // showing "Compacting…" and a failure notice at the same time.
  assert.deepEqual(parsed(socket).slice(before).map((m) => (m as { payload: unknown }).payload), [
    { kind: 'status', event: 'compacting', active: false },
    { kind: 'status', event: 'error', message: 'Context overflow recovery failed' },
  ]);
});

test('an accepted model switch reports the new window', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setUsage({ tokens: 100, contextWindow: 200000 });
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    ['usage'],
  );
});

test('a refused model switch reports nothing about usage', async () => {
  const harness = makeHarness();
  harness.pi.modelAccepted = false;
  const ctx = harness.start();
  ctx.setUsage({ tokens: 100, contextWindow: 200000 });
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    [],
  );
});

test('a pi without getContextUsage emits no usage frame', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete ctx.getContextUsage;
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    [],
  );
  // The history reply itself must still arrive: a missing usage reading is not
  // allowed to take the transcript down with it.
  assert.ok(parsed(socket).some((m) => m.type === 'history'));
});

test('an undefined usage reading emits no usage frame', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setUsage(undefined);
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    [],
  );
});

test('a throwing getContextUsage does not escape and costs only the reading', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.getContextUsage = () => {
    throw new Error('usage exploded');
  };
  const socket = harness.sockets[0];
  socket.open();
  assert.doesNotThrow(() => {
    socket.message({
      protocolVersion: PROTOCOL_VERSION,
      type: 'history-request',
      sessionId: 'sess-1',
    });
  });
  assert.deepEqual(harness.writes, []);
  assert.ok(parsed(socket).some((m) => m.type === 'history'));
});

test('stream deltas never sample the context', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const update = (): void => {
    harness.pi.handlers.get('message_update')!(
      {
        type: 'message_update',
        message: {},
        assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: 'x', partial: {} },
      },
      ctx,
    );
  };
  for (let index = 0; index < 20; index += 1) update();
  // Reading it walks the whole session projection, so it is a boundary cost and
  // must never land on the delta path.
  assert.equal(ctx.usageCalls(), 0);
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.equal(ctx.usageCalls(), 1);
});

test('a history-request from the hub is answered with a history message', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  const history = parsed(socket).find((m) => m.type === 'history')!;
  assert.equal(history.sessionId, 'sess-1');
  assert.deepEqual(history.entries, [{ type: 'message', id: 'e1' }]);
});

test('history-request projects the active branch, not the whole file', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // a1 is on an abandoned branch; only b1/b2 are on the active one.
  ctx.setEntries([
    { type: 'message', id: 'a1', message: { role: 'user', content: 'abandoned' } },
    { type: 'message', id: 'b1', message: { role: 'user', content: 'kept' } },
    { type: 'message', id: 'b2', message: { role: 'assistant', content: 'reply' } },
  ]);
  ctx.setBranchEntries([
    { type: 'message', id: 'b1', message: { role: 'user', content: 'kept' } },
    { type: 'message', id: 'b2', message: { role: 'assistant', content: 'reply' } },
  ]);
  const socket = harness.sockets[0];
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  const history = parsed(socket).find((m) => m.type === 'history');
  assert.ok(history, 'a history frame must be sent');
  const entries = history.entries as Array<{ id: string }>;
  assert.deepEqual(entries.map((entry) => entry.id), ['b1', 'b2']);
});

test('a throwing getEntries on the history-request path does not escape and writes nothing', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0];
  socket.open();
  ctx.sessionManager.getEntries = () => {
    throw new Error('entries exploded');
  };
  assert.doesNotThrow(() => {
    socket.message({
      protocolVersion: PROTOCOL_VERSION,
      type: 'history-request',
      sessionId: 'sess-1',
    });
  });
  assert.deepEqual(harness.writes, []);
});

test('setSessionName sets the session name', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'setSessionName', { name: 'Phone chat' });
  assert.deepEqual(harness.pi.sessionNames, ['Phone chat']);
});

test("listCommands answers with pi's commands, dropping source and absent descriptions", async () => {
  const harness = makeHarness();
  harness.pi.commands = [
    {
      name: 'review',
      description: 'Review the working tree',
      source: 'extension',
      sourceInfo: { path: '/ext/review.md' },
    },
    { name: 'implement-vetted', source: 'prompt', sourceInfo: { path: '/prompts/implement-vetted.md' } },
  ];
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  // `source`/`sourceInfo` must not travel, and an absent description must not
  // become an empty string: the app needs a label and an optional subtitle only.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-listCommands',
    ok: true,
    commands: [
      { name: 'review', description: 'Review the working tree' },
      { name: 'implement-vetted' },
    ],
  });
});

test('a listCommands reply carries no queued flag', async () => {
  const harness = makeHarness();
  harness.pi.commands = [{ name: 'review' }];
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  // `sendCommandResult` is a shared path; only the prompt branch may set the
  // queued key, so a command result must stay exactly its own shape.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-listCommands',
    ok: true,
    commands: [{ name: 'review' }],
  });
});

test('listCommands reports failure when pi has no getCommands method', async () => {
  const harness = makeHarness();
  // Older pi: the method is absent, so the bridge's optional call must
  // short-circuit. Deleting it is what exercises `?.`; a present method that
  // returns `undefined` takes the `raw === undefined` guard instead.
  (harness.pi as { getCommands?: unknown }).getCommands = undefined;
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as {
    type: string;
    ok: boolean;
    error?: string;
    commands?: unknown;
  };
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
  // The specific reason matters: a plain allowlist refusal would also be
  // `ok:false`, so this pins the bridge's own no-list branch.
  assert.equal(result.error, 'commands unavailable');
  assert.equal(result.commands, undefined);
});

test('listCommands reports failure when getCommands returns undefined', async () => {
  const harness = makeHarness();
  harness.pi.commandsAvailable = false;
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as {
    type: string;
    ok: boolean;
    error?: string;
    commands?: unknown;
  };
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
  assert.equal(result.error, 'commands unavailable');
  assert.equal(result.commands, undefined);
});

test('listCommands preserves duplicate names in pi order', async () => {
  const harness = makeHarness();
  harness.pi.commands = [
    { name: 'review', description: 'first' },
    { name: 'other' },
    { name: 'review', description: 'second' },
    // Malformed entries are skipped by the `continue` path, never crash the
    // loop and never reach the wire.
    null,
    42,
    'oops',
  ] as unknown as typeof harness.pi.commands;
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as {
    commands: Array<{ name: string; description?: string }>;
  };
  // Duplicates are preserved and ordered: a future dedupe must be deliberate.
  assert.deepEqual(result.commands, [
    { name: 'review', description: 'first' },
    { name: 'other' },
    { name: 'review', description: 'second' },
  ]);
});

test('listModels returns the available models projected to provider, id and name', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setAvailable([
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
    { provider: 'openai', id: 'gpt-5', name: 'GPT-5' },
  ]);
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; models?: unknown };
  assert.equal(result.ok, true, `listModels was refused: ${String((result as { error?: string }).error)}`);
  assert.deepEqual(result.models, [
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
    { provider: 'openai', id: 'gpt-5', name: 'GPT-5' },
  ]);
});

test('listModels drops an entry missing provider, id or name', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setAvailable([
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
    { provider: 'anthropic', name: 'no id' },
    { id: 'no-provider', name: 'N' },
    { provider: 'p', id: 'm' },
    null,
    42,
    'oops',
  ]);
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { models?: unknown };
  assert.deepEqual(result.models, [
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
  ]);
});

test('listModels never lets a credential or extra model field reach the wire', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setAvailable([
    {
      provider: 'p',
      id: 'm',
      name: 'M',
      headers: { authorization: 'secret' },
      baseUrl: 'http://x',
      compat: { something: true },
      cost: { input: 1 },
    },
  ]);
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { models?: unknown };
  // Deep equality, not a field check: an extra key would fail this too.
  assert.deepEqual(result.models, [{ provider: 'p', id: 'm', name: 'M' }]);
});

test('an older pi without a registry is refused, not reported as empty', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.removeRegistry();
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string; models?: unknown };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'models unavailable');
  // `[]` would be a lie: the app must not show an empty picker as a real answer.
  assert.equal(result.models, undefined);
});

test('a registry whose getAvailable is not an array is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.modelRegistry = {
    getAvailable: () => 'nope' as unknown as unknown[],
    find: () => undefined,
  };
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'models unavailable');
});

test('a registry whose getAvailable throws reports the thrown message', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.modelRegistry = {
    getAvailable: () => {
      throw new Error('registry exploded');
    },
    find: () => undefined,
  };
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // The throw must reach `dispatch`'s catch and surface verbatim, not be
  // swallowed into a generic refusal.
  assert.equal(result.error, 'registry exploded');
});
