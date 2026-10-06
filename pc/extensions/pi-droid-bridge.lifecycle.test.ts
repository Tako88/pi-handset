// mode guard, silence, lifecycle, transport and endpoint discovery.
// Split from the bridge test file; test blocks are byte-exact.
//
// Preserved from the original bridge test file:
//
// ---------------------------------------------------------------------------
// Silence
// ---------------------------------------------------------------------------
//
// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------
//
// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------
//
// ---------------------------------------------------------------------------
// Endpoint discovery
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, beforeEach } from 'node:test';
import { PROTOCOL_VERSION } from '../src/protocol/protocol.ts';
import { writeDiscovery } from '../src/hub/discovery.ts';
import { loadOrCreateToken } from '../src/hub/auth.ts';
import { SESSION_COMMAND_NAME } from '../src/bridge/commands.ts';
import { readEndpoint, resetSessionLinkageForTests } from './pi-droid-bridge.ts';
import { StubCommandCtx, makeHarness, parsed, sendCommand } from '../test/support/bridge-harness.ts';

beforeEach(() => resetSessionLinkageForTests());

test('an inert mode opens no socket', () => {
  const harness = makeHarness();
  harness.start('print');
  assert.equal(harness.sockets.length, 0);
});

test('an inert mode writes nothing', () => {
  const harness = makeHarness();
  harness.start('json');
  assert.deepEqual(harness.writes, []);
});

test('nothing is written without PI_DROID_DEBUG=1', () => {
  const harness = makeHarness({ resolveEndpoint: () => null });
  harness.start();
  assert.deepEqual(harness.writes, []);
});

test('debug output goes to stderr when PI_DROID_DEBUG=1', () => {
  const harness = makeHarness({ env: { PI_DROID_DEBUG: '1' }, resolveEndpoint: () => null });
  harness.start();
  assert.ok(harness.writes.length > 0);
  assert.ok(harness.writes.every((write) => write.stream === 'stderr'));
});

test('the factory opens no socket', () => {
  const harness = makeHarness();
  assert.equal(harness.sockets.length, 0);
});

test('the socket opens in session_start', () => {
  const harness = makeHarness();
  harness.start();
  assert.equal(harness.sockets.length, 1);
});

test('register carries the session identity', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.sessionId, 'sess-1');
  assert.equal(register.sessionFile, '/sessions/sess-1.jsonl');
  assert.equal(register.cwd, '/work');
  assert.equal(register.model, 'test-model');
  assert.equal(register.thinkingLevel, 'medium');
  assert.equal(register.mode, 'tui');
  assert.equal(register.pid, process.pid);
});

test('session_shutdown closes the socket', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  assert.equal(socket.closeCalls.length, 1);
});

test('session_shutdown is idempotent', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  assert.equal(socket.closeCalls.length, 1);
});

test('a new session_start closes the previous socket and re-registers', () => {
  const harness = makeHarness();
  harness.start();
  const first = harness.sockets[0]!;
  first.open();
  harness.start('tui');
  const second = harness.sockets[1]!;
  second.open();
  assert.equal(first.closeCalls.length, 1);
  assert.equal(second.sent.filter((text) => JSON.parse(text).type === 'register').length, 1);
});

test('the retained context follows a session switch', async () => {
  const harness = makeHarness();
  harness.start();
  harness.sockets[0]!.open();
  const secondCtx = harness.start();
  const secondSocket = harness.sockets[1]!;
  secondSocket.open();
  await sendCommand(harness.pi, secondSocket, 'abort');
  assert.equal(secondCtx.aborts(), 1);
});

test('install registers the internal session command', () => {
  const harness = makeHarness();
  // The bridge can only drive a session action through a real command context,
  // and a command context is reachable only from a registered command. One
  // registration, once per install.
  assert.deepEqual(
    harness.pi.registeredCommands.map((command) => command.name),
    [SESSION_COMMAND_NAME],
  );
});

test('a replacement session_start registers the id it replaced', () => {
  for (const reason of ['new', 'fork', 'resume']) {
    // Real replacement: pi re-runs the extension factory, so the successor's
    // `session_start` lands on a NEW bridge instance that knows the predecessor
    // only through the module-level value. Modelling that needs a second
    // install, not a re-fire on the same instance.
    const real = makeHarness();
    real.start('tui', 'sess-1', 'startup');
    real.sockets[0]!.open();
    real.reinstall();
    real.start('tui', 'sess-2', reason);
    const realSecond = real.sockets[1]!;
    realSecond.open();
    const realRegister = parsed(realSecond).find((m) => m.type === 'register')!;
    assert.equal(
      realRegister.replaces,
      'sess-1',
      `${reason} did not carry replaces across a real replacement`,
    );

    // Same-instance re-fire, which still pins the module-state comparison.
    const inPlace = makeHarness();
    inPlace.start('tui', 'sess-1', 'startup');
    inPlace.sockets[0]!.open();
    inPlace.start('tui', 'sess-2', reason);
    const second = inPlace.sockets[1]!;
    second.open();
    const register = parsed(second).find((m) => m.type === 'register')!;
    assert.equal(register.replaces, 'sess-1', `${reason} did not carry replaces`);
  }
});

test('resetSessionLinkageForTests clears the module-level predecessor', () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  resetSessionLinkageForTests();
  harness.start('tui', 'sess-2', 'new');
  const second = harness.sockets[1]!;
  second.open();
  const register = parsed(second).find((m) => m.type === 'register')!;
  // Without the clear, the module still names sess-1 and the successor would be
  // linked to a session a previous test registered, not this one's.
  assert.equal(register.replaces, undefined, 'the reset must clear the recorded predecessor');
});

test('a non-replacement session_start carries no replaces', () => {
  for (const reason of ['startup', 'reload']) {
    const harness = makeHarness();
    harness.start('tui', 'sess-1', 'startup');
    harness.sockets[0]!.open();
    harness.start('tui', 'sess-2', reason);
    const second = harness.sockets[1]!;
    second.open();
    const register = parsed(second).find((m) => m.type === 'register')!;
    assert.equal(register.replaces, undefined, `${reason} carried replaces`);
  }
});

test('a resume that reloads the same session id carries no replaces', () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  // `/resume` can reload the very id already registered; naming it as replaced
  // would make the app follow a successor that does not exist.
  harness.start('tui', 'sess-1', 'resume');
  const second = harness.sockets[1]!;
  second.open();
  const register = parsed(second).find((m) => m.type === 'register')!;
  assert.equal(register.replaces, undefined);
});

test('replaces survives a register that could not be sent and is cleared only after one that was', () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  harness.start('tui', 'sess-2', 'new');
  // sockets[1] is deliberately left closed, and a label refresh is the one
  // closed-socket path that calls `sendRegister`. It must not consume the
  // replacement: nothing reached the hub, so the app never saw the linkage.
  harness.pi.setSessionName('renamed while closed');
  harness.pi.handlers.get('session_info_changed')!(
    { type: 'session_info_changed' },
    harness.startCtx,
  );
  const second = harness.sockets[1]!;
  second.open();
  const registers = parsed(second).filter((m) => m.type === 'register');
  assert.equal(registers.length, 1);
  assert.equal(registers[0]!.replaces, 'sess-1');
  // A second rename now reaches the open socket, so the flag is consumed and the
  // next register omits it — it must not link a third, later register.
  harness.pi.setSessionName('renamed while open');
  harness.pi.handlers.get('session_info_changed')!(
    { type: 'session_info_changed' },
    harness.startCtx,
  );
  const after = parsed(second).filter((m) => m.type === 'register');
  assert.equal(after.length, 2);
  assert.equal(after[1]!.replaces, undefined);
});

test('sessionNew acknowledges and triggers the registered command', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionNew');
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
  // The only route to a command context is a real command invocation, so the
  // bridge triggers its own registered command rather than calling pi directly.
  assert.deepEqual(
    harness.pi.userMessages.map((message) => message.content),
    [`/${SESSION_COMMAND_NAME} new`],
  );
});

test('the registered handler for new calls newSession exactly once and returns', async () => {
  const harness = makeHarness();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  await handler('new', cmdCtx);
  // The stub throws on a second call, modelling pi's `assertActive`: a handler
  // that touched the context again after `newSession` would blow up here.
  assert.deepEqual(cmdCtx.calls, ['newSession']);
});

test('a cancelled newSession emits an error status instead of a silent ack', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  cmdCtx.setCancel(true);
  await handler('new', cmdCtx);
  // pi resolves `{cancelled:true}` when a `session_before_switch` handler
  // cancels. Without this notice the app would wait on a replacement that will
  // never come.
  const status = parsed(socket).find(
    (message) =>
      message.type === 'event' && (message.payload as { kind?: string }).kind === 'status',
  );
  assert.ok(status, 'a cancelled replacement emitted no status');
  assert.equal((status.payload as { event?: string }).event, 'error');
});

test('a navigateTree failure emits an error status', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  cmdCtx.setThrow(new Error('cannot navigate'));
  await handler('tree t9', cmdCtx);
  // `navigateTree` throws on a streaming/compacting session or an unknown id.
  // The throw must become a notice, never an unhandled rejection inside pi.
  const status = parsed(socket).find(
    (message) =>
      message.type === 'event' && (message.payload as { kind?: string }).kind === 'status',
  );
  assert.ok(status, 'a throwing tree navigation emitted no status');
  assert.equal((status.payload as { event?: string }).event, 'error');
  assert.match((status.payload as { message?: string }).message ?? '', /cannot navigate/);
});

test('an unknown session action emits an error status instead of a silent ack', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  // `dispatch` has already acked `ok:true`; a mistyped action must not fall off
  // the end of the handler silently.
  await handler('bogus t1', new StubCommandCtx());
  const status = parsed(socket).find(
    (message) =>
      message.type === 'event' && (message.payload as { kind?: string }).kind === 'status',
  );
  assert.ok(status, 'an unknown action emitted no status');
  assert.equal((status.payload as { event?: string }).event, 'error');
  assert.equal(
    (status.payload as { message?: string }).message,
    'unknown session action: bogus',
  );
  // An empty action names itself too, rather than printing nothing.
  await handler('', new StubCommandCtx());
  const last = parsed(socket).at(-1) as { payload?: { message?: string } };
  assert.equal(last.payload?.message, 'unknown session action: (empty)');
});

test('sessionTree refuses while pi is working', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionTree', { entryId: 't1' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // The specific reason, not the generic allowlist refusal: `navigateTree`
  // throws mid-stream, so the bridge refuses before triggering the command.
  assert.equal(result.error, 'cannot navigate the tree while pi is working');
  assert.deepEqual(harness.pi.userMessages, []);
});

test('a session_tree event emits a leaf event with the new leaf', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const handler = harness.pi.handlers.get('session_tree');
  assert.ok(handler, 'the bridge must subscribe to pi\'s session_tree event');
  handler!({ type: 'session_tree', newLeafId: 'e9', oldLeafId: 'e1' }, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(emitted.at(-1)?.payload, { kind: 'leaf', leafId: 'e9' });
});

test('a session_tree to the root emits leafId null', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const handler = harness.pi.handlers.get('session_tree');
  assert.ok(handler, 'the bridge must subscribe to pi\'s session_tree event');
  handler!({ type: 'session_tree', newLeafId: null, oldLeafId: 'e1' }, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(emitted.at(-1)?.payload, { kind: 'leaf', leafId: null });
});

test('sessionTree refuses an entry id pi does not know', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // The id was listed earlier but the entry is gone now: pi's navigateTree
  // would throw after the ack, so the refusal must happen at dispatch.
  ctx.setEntries([{ type: 'message', id: 'e1', message: { role: 'user', content: 'hi' } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionTree', { entryId: 'gone' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'unknown entry');
  // Refused before the command is ever triggered.
  assert.deepEqual(harness.pi.userMessages, []);
});

test('sessionFork rejects a non-user entry', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // Forking with the default `before` position requires a user message entry;
  // an assistant entry is not a valid fork target.
  ctx.setEntries([{ type: 'message', id: 'e9', message: { role: 'assistant', content: [] } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionFork', { entryId: 'e9' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'unknown entry');
  // Refused before the command is ever triggered.
  assert.deepEqual(harness.pi.userMessages, []);
});

test('sessionFork rejects a non-message entry that carries a user message', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // A non-message variant that happens to carry a `message` object must not
  // pass the role check: it would only fail later, after `ok:true` was acked.
  ctx.setEntries([{ type: 'compaction', id: 'c9', message: { role: 'user', content: 'x' } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionFork', { entryId: 'c9' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'unknown entry');
  assert.deepEqual(harness.pi.userMessages, []);
});

test('a sessionFork for a user entry triggers the fork with the entry id', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setEntries([{ type: 'message', id: 'e3', message: { role: 'user', content: 'hi' } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionFork', { entryId: 'e3' });
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
  assert.deepEqual(
    harness.pi.userMessages.map((message) => message.content),
    [`/${SESSION_COMMAND_NAME} fork e3`],
  );
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  await handler('fork e3', cmdCtx);
  assert.deepEqual(cmdCtx.calls, ['fork']);
});

test('after a session switch the previous session id is refused as a mismatch', async () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  const secondCtx = harness.start('tui', 'sess-2', 'startup');
  const secondSocket = harness.sockets[1]!;
  secondSocket.open();
  // A stale id from before the replacement must not be dispatched against the
  // successor context. `sendCommand` hardcodes `sess-1`, which is exactly the
  // stale id under test.
  await sendCommand(harness.pi, secondSocket, 'abort');
  const result = parsed(secondSocket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'session mismatch');
  assert.equal(secondCtx.aborts(), 0);
  assert.equal(secondCtx.compacts(), 0);
});

test('commands arriving after shutdown are ignored', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  await sendCommand(harness.pi, socket, 'prompt', { text: 'late' });
  assert.deepEqual(harness.pi.userMessages, []);
});

test('the bridge does not import the ws package', () => {
  const source = readFileSync(new URL('./pi-droid-bridge.ts', import.meta.url), 'utf8');
  assert.equal(/from\s+['"]ws['"]/.test(source), false);
  assert.equal(/require\(\s*['"]ws['"]\s*\)/.test(source), false);
});

test('readEndpoint reads the agent port from discovery and the token from config', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-rt-'));
  const configDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-cfg-'));
  try {
    writeDiscovery(runtimeDir, {
      agentPort: 4321,
      viewerPort: 8787,
      pid: process.pid,
      startedAt: new Date().toISOString(),
      protocolVersion: PROTOCOL_VERSION,
    });
    const { token } = loadOrCreateToken(configDir);
    assert.deepEqual(readEndpoint({ runtimeDir, configDir }), {
      url: 'ws://127.0.0.1:4321',
      token,
    });
  } finally {
    rmSync(runtimeDir, { recursive: true, force: true });
    rmSync(configDir, { recursive: true, force: true });
  }
});

test('readEndpoint reports no hub when there is no discovery file', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-rt-'));
  const configDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-cfg-'));
  try {
    assert.equal(readEndpoint({ runtimeDir, configDir }), null);
  } finally {
    rmSync(runtimeDir, { recursive: true, force: true });
    rmSync(configDir, { recursive: true, force: true });
  }
});
