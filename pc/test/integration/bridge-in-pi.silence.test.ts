// a real pi: silence with no hub, a refused token, and print mode.
// Split from the bipi test file; test blocks are byte-exact.
//
// Preserved from the original bipi test file:
//
// ---------------------------------------------------------------------------
// Step 17 — silence as a real process
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { afterEach, beforeEach, test } from 'node:test';
import { loadOrCreateToken } from '../../src/hub/auth.ts';
import { writeDiscovery } from '../../src/hub/discovery.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

import { bridgePath, harnessPath, BOOT_TIMEOUT_MS, runtimeDir, configDir, setupBridgeInPi, cleanupBridgeInPi, waitFor, waitExit, spawnPi, probeRpcChannel, assertStdoutIsPureJsonl, freePort, startHub, publishDiscovery, writeTokenAt, connectViewer } from '../support/bridge-in-pi-harness.ts';

beforeEach(setupBridgeInPi);
afterEach(cleanupBridgeInPi);

test('with no hub running, the active bridge writes only to stderr and rpc stdout stays JSONL', async () => {
  // A discovery record that names a port nobody listens on: the bridge is
  // active, dials, and fails — the very case where a stray stdout write would
  // corrupt pi's protocol. The pid is alive (this test process) so the record
  // is not discarded as stale.
  const deadPort = await freePort();
  writeDiscovery(runtimeDir, {
    agentPort: deadPort,
    viewerPort: deadPort,
    pid: process.pid,
    startedAt: new Date().toISOString(),
    protocolVersion: PROTOCOL_VERSION,
  });
  loadOrCreateToken(configDir);

  const run = spawnPi(['--mode', 'rpc', '-ne', '-e', bridgePath, '--no-session', '-nc']);

  await waitFor(
    () => /pi-droid bridge: (socket error|socket closed)/.test(run.stderr()),
    `the bridge to attempt a dial and log the failure to stderr (stderr tail: ${run
      .stderr()
      .slice(-400)})`,
    BOOT_TIMEOUT_MS,
  );

  await probeRpcChannel(run);
  assertStdoutIsPureJsonl(run);
  assert.match(
    run.stderr(),
    /pi-droid bridge:/,
    'the active bridge must log to stderr under PI_DROID_DEBUG=1',
  );
});

test('when the hub refuses the token, the bridge still writes only to stderr and stdout stays JSONL', async () => {
  // The hub's token and the bridge's persisted token differ, so the bridge's
  // `hello` is rejected. Its own register then trips the protocol gate; the
  // hub closes the socket. Silence on stdout is asserted across the rejection.
  const { token } = loadOrCreateToken(configDir);
  const hub = await startHub({ token, maxAuthAttempts: 1, authCloseDelayMs: 10 });
  publishDiscovery(hub);
  writeTokenAt(configDir, 'b'.repeat(64));

  const run = spawnPi(['--mode', 'rpc', '-ne', '-e', bridgePath, '--no-session', '-nc']);

  await waitFor(
    () => /pi-droid bridge: socket closed/.test(run.stderr()),
    `the bridge to dial the hub and log its rejection (stderr tail: ${run
      .stderr()
      .slice(-400)})`,
    BOOT_TIMEOUT_MS,
  );

  await probeRpcChannel(run);
  assertStdoutIsPureJsonl(run);
  assert.match(run.stderr(), /pi-droid bridge: socket closed/);
});

test('in print mode the bridge is inert (mode-guard evidence, not silence-while-active)', async () => {
  // Deliberately labelled: `--print` proves the guard bails, not that an active
  // bridge is silent. The rpc tests above carry that claim.
  const { token } = loadOrCreateToken(configDir);
  const hub = await startHub({ token });
  publishDiscovery(hub);

  const run = spawnPi([
    '-p',
    '-ne',
    '-e',
    harnessPath,
    '-e',
    bridgePath,
    '--provider',
    'faux',
    '--model',
    'faux-1',
    '--no-session',
    '-nc',
    'say the word',
  ]);
  // `pi -p` reads stdin to EOF when it is a pipe; signal end of input.
  run.child.stdin!.end();
  await waitExit(run.child);

  assert.match(run.stderr(), /pi-droid bridge: inert in print mode/);
  assert.equal(run.child.exitCode, 0, `pi --print failed: ${run.stderr().slice(-400)}`);

  // Inert means no register: the registry stays empty.
  const viewer = await connectViewer(hub.viewerPort, token);
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    const message = await viewer.tryNext(500);
    if (message === undefined || message.type !== 'sessions') continue;
    assert.deepEqual(message.sessions, [], 'an inert bridge must never register');
    return;
  }
  assert.fail('the hub never sent the authenticated viewer a session list');
});
