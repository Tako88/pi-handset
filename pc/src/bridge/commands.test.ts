/**
 * The command allowlist, its refusals, and the mode guard, exercised through
 * `src/bridge/commands.ts`.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { PROTOCOL_VERSION } from '../protocol/protocol.ts';
import { COMMAND_ALLOWLIST as HUB_COMMAND_ALLOWLIST } from '../hub/hub.ts';
import {
  isActiveMode,
  COMMAND_ALLOWLIST as BRIDGE_COMMAND_ALLOWLIST,
  COMMAND_NOT_ALLOWED,
  SESSION_COMMAND_NAME,
} from './commands.ts';
import {
  makeHarness,
  parsed,
  sendCommand,
  tick,
} from '../../test/support/bridge-harness.ts';

test('the bridge and hub command allowlists are identical', () => {
  // Drift is silent and costly: the hub-allows/bridge-refuses direction yields
  // `command not allowed`, the other `unknown command`, and the only other net
  // is the real-pi capstone, which pays a pi spawn. This is test-only coupling.
  assert.deepEqual(
    [...BRIDGE_COMMAND_ALLOWLIST].sort(),
    [...HUB_COMMAND_ALLOWLIST].sort(),
  );
});

test('every allowlisted command is actually dispatched', async () => {
  // The allowlist is a promise to the app, and nothing checked that the
  // dispatcher keeps it: a name on the list with no case falls through to the
  // `default` and the app is told `command not allowed` for a command the list
  // says it may send. `fetchHistory` is handled in `dispatch`, *before*
  // `dispatchCommand`, which is exactly how a reader of the switch alone
  // concludes it is unimplemented — it is not.
  // The session-control names must stay covered: iterating the allowlist
  // silently shrinks if one is dropped, so pin them here.
  for (const name of ['listTree', 'sessionNew', 'sessionTree', 'sessionFork']) {
    assert.ok(BRIDGE_COMMAND_ALLOWLIST.has(name), `${name} is missing from the allowlist`);
  }
  for (const name of BRIDGE_COMMAND_ALLOWLIST) {
    const harness = makeHarness();
    harness.start();
    const socket = harness.sockets[0]!;
    socket.open();
    // Deliberately empty args: every real case answers with its own specific
    // complaint (`missing text`, `missing model`, …) and only a missing case
    // answers with the generic refusal. A case's own error is proof it exists.
    await sendCommand(harness.pi, socket, name);
    const result = parsed(socket).find((m) => m.type === 'command-result') as
      | { ok: boolean; error?: string }
      | undefined;
    // Presence first: `result?.error` is `undefined` when no reply arrived at
    // all, which would satisfy the assertion below and turn this guard into a
    // vacuous pass — the exact failure it exists to catch.
    assert.ok(result, `${name} produced no command-result`);
    assert.notEqual(
      result.error,
      COMMAND_NOT_ALLOWED,
      `${name} is allowlisted but the dispatcher has no case for it`,
    );
  }
});

// ---------------------------------------------------------------------------
// Refusals
// ---------------------------------------------------------------------------

test('exec is refused, not ignored', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'exec', { command: 'rm', args: ['-rf', '/'] });
  const result = parsed(socket).at(-1) as { type: string; ok: boolean };
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
});

test('shutdown is refused without shutting down', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'shutdown');
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('setActiveTools is refused', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setActiveTools', { tools: ['bash'] });
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('an unknown command is refused', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'definitelyNotACommand');
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('a command arriving after the session turns inert is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start('tui');
  const socket = harness.sockets[0]!;
  socket.open();
  // A future socket path must not be able to dispatch once the mode is inert;
  // the guard is re-checked at dispatch, not only at session_start.
  ctx.mode = 'json';
  await sendCommand(harness.pi, socket, 'prompt', { text: 'hi' });
  assert.deepEqual(harness.pi.userMessages, []);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('a command whose sessionId is not this session is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c-other',
    sessionId: 'other-session',
    name: 'abort',
  });
  await tick();
  assert.equal(ctx.aborts(), 0);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('refusal is not defeatable by casing or whitespace', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  for (const name of ['Prompt', 'PROMPT', ' prompt', 'prompt ', 'exec ', 'Shutdown', 'setactivetools']) {
    await sendCommand(harness.pi, socket, name, { text: 'hi' });
    const result = parsed(socket).at(-1) as { ok: boolean };
    assert.equal(result.ok, false, `${name} was not refused`);
  }
  assert.deepEqual(harness.pi.userMessages, []);
});

// ---------------------------------------------------------------------------
// Mode guard
// ---------------------------------------------------------------------------

test('tui and rpc are active modes', () => {
  assert.equal(isActiveMode('tui'), true);
  assert.equal(isActiveMode('rpc'), true);
});

test('json and print are inert modes', () => {
  assert.equal(isActiveMode('json'), false);
  assert.equal(isActiveMode('print'), false);
});

test("listCommands omits the bridge's own session command", async () => {
  const harness = makeHarness();
  // pi exposes registered extension commands through `getCommands()`; the
  // bridge's own command must never appear in the app's `/` overlay. The filter
  // hides the bare name and pi's `:N` duplicate form only — a hypothetical
  // `pi-droid-session-foo` is still a real, distinct command.
  harness.pi.commands = [
    { name: SESSION_COMMAND_NAME },
    { name: `${SESSION_COMMAND_NAME}:2` },
    { name: `${SESSION_COMMAND_NAME}-foo` },
    { name: 'ping' },
  ];
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as { commands: Array<{ name: string }> };
  assert.deepEqual(
    result.commands.map((command) => command.name),
    [`${SESSION_COMMAND_NAME}-foo`, 'ping'],
  );
});
