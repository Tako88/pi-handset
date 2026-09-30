/**
 * M9 — the bridge inside a *real* pi, and silence as a real process.
 *
 * Two behaviours, both against a spawned `pi` binary (version 0.87.1):
 *
 * 1. A real pi is started in `--mode rpc` with the bridge and a faux-provider
 *    harness extension loaded (`-ne` disables discovery, explicit `-e` still
 *    loads). The hub receives the bridge's `register`, a prompt driven *through
 *    the hub* produces the faux provider's stream and a terminal `agent_settled`
 *    state, and the viewer gets its `command-result`.
 *
 * 2. In `--mode rpc`, stdout is pi's JSONL protocol channel. The bridge must
 *    never write there — under any outcome (no hub, hub refuses the token). The
 *    bridge's own writes are asserted on stderr, never byte-equality across pi
 *    runs.
 *
 * pi is deliberately driven through the hub rather than pi's stdin: it also
 * exercises the allowlist dispatch path against a live pi.
 *
 * `--print` is only evidence of the mode guard (the bridge is inert there),
 * never of silence while active. It is labelled as such.
 */

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, test } from 'node:test';

import { WebSocket } from 'ws';

import { loadOrCreateToken } from '../../src/hub/auth.ts';
import { writeDiscovery } from '../../src/hub/discovery.ts';
import { createHub } from '../../src/hub/hub.ts';
import type { Hub } from '../../src/hub/hub.ts';
import { createTicketStore } from '../../src/hub/pairing.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

const bridgePath = fileURLToPath(new URL('../../extensions/pi-droid-bridge.ts', import.meta.url));
const harnessPath = fileURLToPath(new URL('./support/faux-provider.ts', import.meta.url));

const FAUX_TEXT = 'FAUX_OK';
/** Generous: a real pi boots slower than any fake, and this box may be busy. */
const BOOT_TIMEOUT_MS = 20_000;
const STREAM_TIMEOUT_MS = 30_000;
/** Bound on a child's death wait: a hang must fail, never stall `node:test`. */
const EXIT_TIMEOUT_MS = 30_000;

let tmpRoot: string;
let runtimeDir: string;
let configDir: string;
let childCwd: string;

const children: ChildProcess[] = [];
const hubs: Hub[] = [];
const viewers: Viewer[] = [];

beforeEach(() => {
  tmpRoot = mkdtempSync(join(tmpdir(), 'pi-droid-in-pi-'));
  runtimeDir = join(tmpRoot, 'runtime');
  configDir = join(tmpRoot, 'config');
  childCwd = join(tmpRoot, 'cwd');
  mkdirSync(runtimeDir, { recursive: true, mode: 0o700 });
  mkdirSync(configDir, { recursive: true, mode: 0o700 });
  mkdirSync(childCwd, { recursive: true });
});

afterEach(async () => {
  // Never leak a socket, a child or a listener, even when a test failed. Kill
  // by the pid we spawned; `pkill -f` would match this test run's own shell.
  for (const viewer of viewers) {
    try {
      viewer.ws.terminate();
    } catch {
      // Already gone.
    }
  }
  viewers.length = 0;

  const exits = children.map((child) => {
    if (child.exitCode === null && child.signalCode === null) {
      child.stdin?.destroy();
      child.kill('SIGKILL');
    }
    return waitExit(child);
  });
  await Promise.all(exits);
  children.length = 0;

  while (hubs.length > 0) {
    await hubs.pop()!.close();
  }

  rmSync(tmpRoot, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(predicate: () => boolean, what: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await delay(20);
  }
  throw new Error(`timed out waiting for ${what}`);
}

/**
 * Waits for a spawned child to be gone. Resolves on the first of `exit`,
 * `close` or `error`: a failed spawn (ENOENT/EACCES) emits `error` and never a
 * guaranteed `exit`, so waiting on `exit` alone would hang `node:test` forever
 * (there is no default timeout). The wait is also bounded — a child that will
 * not die is SIGKILLed and the promise rejects with its pid and command, so a
 * hang inside `afterEach` cannot block every subsequent test in the file.
 */
function waitExit(child: ChildProcess): Promise<void> {
  return new Promise((resolve, reject) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve();
      return;
    }
    const command = child.spawnargs.join(' ');
    let timer: ReturnType<typeof setTimeout>;
    const settle = (): void => {
      clearTimeout(timer);
      child.removeListener('exit', settle);
      child.removeListener('close', settle);
      child.removeListener('error', settle);
      resolve();
    };
    timer = setTimeout(() => {
      child.removeListener('exit', settle);
      child.removeListener('close', settle);
      child.removeListener('error', settle);
      child.kill('SIGKILL');
      reject(
        new Error(
          `child ${String(child.pid)} did not exit within ${EXIT_TIMEOUT_MS}ms and was SIGKILLed: ${command}`,
        ),
      );
    }, EXIT_TIMEOUT_MS);
    child.once('exit', settle);
    child.once('close', settle);
    child.once('error', settle);
  });
}

interface PiRun {
  child: ChildProcess;
  stdout(): string;
  stderr(): string;
  send(line: string): void;
  spawnError(): Error | null;
}

function spawnPi(args: string[], extraEnv: Record<string, string> = {}): PiRun {
  const child = spawn('pi', args, {
    cwd: childCwd,
    env: {
      ...process.env,
      PI_DROID_RUNTIME_DIR: runtimeDir,
      XDG_CONFIG_HOME: configDir,
      PI_DROID_DEBUG: '1',
      ...extraEnv,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  children.push(child);

  let stdout = '';
  let stderr = '';
  let error: Error | null = null;
  child.stdout!.on('data', (chunk) => {
    stdout += String(chunk);
  });
  child.stderr!.on('data', (chunk) => {
    stderr += String(chunk);
  });
  child.on('error', (cause) => {
    error = cause;
  });

  return {
    child,
    stdout: () => stdout,
    stderr: () => stderr,
    send: (line) => child.stdin!.write(`${line}\n`),
    spawnError: () => error,
  };
}

/** Waits for a JSONL RPC response on stdout, proving the protocol channel lives. */
async function probeRpcChannel(run: PiRun): Promise<void> {
  run.send(JSON.stringify({ id: 'm9-probe', type: 'get_state' }));
  await waitFor(
    () => stdoutRecords(run.stdout()).some((record) => record.type === 'response'),
    `an RPC 'get_state' response on stdout (child error: ${String(run.spawnError())}; stderr tail: ${run
      .stderr()
      .slice(-400)})`,
    BOOT_TIMEOUT_MS,
  );
}

/** Complete stdout lines, dropping any trailing partial record. */
function completeLines(text: string): string[] {
  const lines = text.split('\n');
  lines.pop();
  return lines.filter((line) => line.trim().length > 0);
}

function stdoutRecords(text: string): Array<Record<string, unknown>> {
  const records: Array<Record<string, unknown>> = [];
  for (const line of completeLines(text)) {
    try {
      records.push(JSON.parse(line) as Record<string, unknown>);
    } catch {
      // A corrupt line is the bug `assertStdoutIsPureJsonl` exists to report
      // (naming the offending line). This probe only polls, so it must skip
      // such a line rather than throw a bare SyntaxError from inside a
      // `waitFor` predicate and obscure the corruption.
    }
  }
  return records;
}

/**
 * Every complete stdout line must be one JSON object: in `--mode rpc` stdout is
 * the reserved protocol channel, and a single bridge write corrupts it.
 */
function assertStdoutIsPureJsonl(run: PiRun): void {
  const bad = completeLines(run.stdout()).filter((line) => {
    try {
      JSON.parse(line);
      return false;
    } catch {
      return true;
    }
  });
  assert.deepEqual(bad, [], `stdout carried non-JSON lines: ${bad.join(' | ')}`);
  assert.ok(
    !run.stdout().includes('pi-droid bridge'),
    'the bridge must never write to stdout',
  );
}

/** A port nobody is listening on right now. */
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo;
      server.close(() => resolve(port));
    });
  });
}

// ---------------------------------------------------------------------------
// Hub + viewer helpers
// ---------------------------------------------------------------------------

async function startHub(overrides: Partial<Parameters<typeof createHub>[0]> = {}): Promise<Hub> {
  const hub = await createHub({
    token: loadOrCreateToken(configDir).token,
    tickets: createTicketStore(),
    viewerPort: 0,
    viewerHost: '127.0.0.1',
    ...overrides,
  });
  hubs.push(hub);
  return hub;
}

function publishDiscovery(hub: Hub): void {
  writeDiscovery(runtimeDir, {
    agentPort: hub.agentPort,
    viewerPort: hub.viewerPort,
    pid: process.pid,
    startedAt: new Date().toISOString(),
    protocolVersion: PROTOCOL_VERSION,
  });
}

function writeTokenAt(dir: string, token: string): void {
  const tokenDir = join(dir, 'pi-droid');
  mkdirSync(tokenDir, { recursive: true, mode: 0o700 });
  writeFileSync(join(tokenDir, 'token'), token, { mode: 0o600 });
}

interface Queue {
  push(message: Record<string, unknown>): void;
  next(timeoutMs: number): Promise<Record<string, unknown>>;
}

/** A FIFO with at most one pending waiter; `ws` delivers in order. */
function messageQueue(): Queue {
  const items: Record<string, unknown>[] = [];
  let waiter: ((value: Record<string, unknown>) => void) | null = null;

  function next(timeoutMs: number): Promise<Record<string, unknown>> {
    const queued = items.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        waiter = null;
        reject(new Error('timed out waiting for a message'));
      }, timeoutMs);
      waiter = (value) => {
        clearTimeout(timer);
        resolve(value);
      };
    });
  }

  return {
    push(message) {
      if (waiter !== null) {
        const resolve = waiter;
        waiter = null;
        resolve(message);
      } else {
        items.push(message);
      }
    },
    next,
  };
}

interface Viewer {
  readonly ws: WebSocket;
  send(message: unknown): void;
  tryNext(timeoutMs?: number): Promise<Record<string, unknown> | undefined>;
}

function connectViewer(port: number, token: string): Promise<Viewer> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const queue = messageQueue();
  ws.on('message', (data) => {
    queue.push(JSON.parse(String(data)) as Record<string, unknown>);
  });

  return new Promise((resolve, reject) => {
    ws.once('error', reject);
    ws.once('open', () => {
      const viewer: Viewer = {
        ws,
        send: (message) => ws.send(JSON.stringify(message)),
        async tryNext(timeoutMs = 300) {
          try {
            return await queue.next(timeoutMs);
          } catch {
            return undefined;
          }
        },
      };
      viewers.push(viewer);
      viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token });
      resolve(viewer);
    });
  });
}

interface SessionSummary {
  sessionId: string;
  label: string;
  agentState: string;
}

async function waitForSession(viewer: Viewer, timeoutMs: number): Promise<SessionSummary> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const message = await viewer.tryNext(Math.min(1000, Math.max(1, deadline - Date.now())));
    if (
      message !== undefined &&
      message.type === 'sessions' &&
      Array.isArray(message.sessions) &&
      message.sessions.length > 0
    ) {
      return message.sessions[0] as SessionSummary;
    }
  }
  throw new Error('timed out waiting for the bridge to register a session with the hub');
}

interface Collected {
  streams: Array<{ seq: number; text: string }>;
  /** Content-free phase frames, in arrival order. */
  phases: Array<{ seq: number; payload: Record<string, unknown> }>;
  running: boolean;
  settled: boolean;
  /** Relayed `message` payloads, in arrival order, tagged by role. */
  messages: Array<{ role: string; payload: Record<string, unknown> }>;
  /** True when the assistant message arrived before the terminal `settled` state. */
  assistantBeforeSettled: boolean;
  /** True when a phase frame preceded the first assistant message. */
  phaseBeforeAssistant: boolean;
  result: Record<string, unknown> | null;
}

/**
 * Reads relayed events until the prompt has fully settled: the terminal message
 * and `agent` state, plus the `command-result`. Absence is a real failure, not
 * a quietly shorter list.
 */
async function collectPrompt(viewer: Viewer, id: string, timeoutMs: number): Promise<Collected> {
  const collected: Collected = {
    streams: [],
    phases: [],
    running: false,
    settled: false,
    messages: [],
    assistantBeforeSettled: false,
    phaseBeforeAssistant: false,
    result: null,
  };
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (collected.result !== null && collected.settled) break;
    const message = await viewer.tryNext(Math.min(1000, Math.max(1, deadline - Date.now())));
    if (message === undefined) continue;
    if (message.type === 'command-result' && message.id === id) {
      collected.result = message;
      continue;
    }
    if (message.type !== 'event') continue;
    const payload = message.payload as Record<string, unknown> | undefined;
    if (payload === undefined) continue;
    if (payload.kind === 'stream') {
      if (payload.phase !== undefined) {
        collected.phases.push({ seq: payload.seq as number, payload });
        if (!collected.messages.some((entry) => entry.role === 'assistant')) {
          collected.phaseBeforeAssistant = true;
        }
      } else {
        collected.streams.push({ seq: payload.seq as number, text: payload.text as string });
      }
    } else if (payload.kind === 'message') {
      const body = payload.message as Record<string, unknown> | undefined;
      const role = typeof body?.role === 'string' ? body.role : 'unknown';
      collected.messages.push({ role, payload });
      if (role === 'assistant' && !collected.settled) {
        collected.assistantBeforeSettled = true;
      }
    } else if (payload.kind === 'agent') {
      if (payload.state === 'running') collected.running = true;
      if (payload.state === 'settled') collected.settled = true;
    }
  }
  return collected;
}

/**
 * Boots a hub, a real pi carrying the bridge and the faux harness, and drives
 * one prompt end to end. Returns everything the hub relayed to the viewer.
 * Children, hubs and viewers are torn down by `afterEach`.
 */
async function drivePrompt(extraEnv: Record<string, string> = {}): Promise<Collected> {
  const { token } = loadOrCreateToken(configDir);
  const hub = await startHub({ token });
  publishDiscovery(hub);

  spawnPi(
    [
      '--mode',
      'rpc',
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
    ],
    { PI_DROID_FAUX_TEXT: FAUX_TEXT, ...extraEnv },
  );

  const viewer = await connectViewer(hub.viewerPort, token);
  const session = await waitForSession(viewer, BOOT_TIMEOUT_MS);
  assert.ok(session.sessionId.length > 0, 'the register must carry a session id');
  assert.ok(session.label.length > 0, 'the register must produce a viewer-safe label');
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: session.sessionId });

  const id = 'prompt-1';
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId: session.sessionId,
    name: 'prompt',
    args: { text: 'say the word' },
  });

  return collectPrompt(viewer, id, STREAM_TIMEOUT_MS);
}

// ---------------------------------------------------------------------------
// Step 16 — a real pi, driven through the hub
// ---------------------------------------------------------------------------

test('a real pi with the bridge registers and a hub prompt streams from the faux provider', async () => {
  const collected = await drivePrompt();

  // This is what M9 asks the hub to have received: the register (above), the
  // stream sequence, the final assistant message, the terminal agent state, and
  // the command-result.
  //
  // The final assistant message matters: the app commits the streamed text into
  // its transcript only on a `message` payload, and clears the streaming buffer
  // on the non-running agent state. If the message arrives after `settled`, the
  // reply is wiped before it can be committed — so the ordering is asserted, not
  // assumed. Real pi delivers the completion as a `message_end` extension event.
  assert.ok(collected.result, 'no command-result arrived for the prompt');
  assert.equal(collected.result.ok, true, `prompt was refused: ${String(collected.result.error)}`);
  assert.ok(collected.running, 'the agent never reported the running state');
  assert.ok(collected.settled, 'the agent never settled');

  // Per-role counts, not a single total: M1 relays the user's own prompt too,
  // and a double-emitted user (or a future toolResult) must not pass silently.
  const userMessages = collected.messages.filter((entry) => entry.role === 'user');
  const assistantMessages = collected.messages.filter((entry) => entry.role === 'assistant');
  assert.equal(
    userMessages.length,
    1,
    `exactly one user message must be relayed, got ${collected.messages.length} total`,
  );
  assert.equal(assistantMessages.length, 1, 'exactly one assistant message must be relayed');
  assert.equal(collected.messages.length, 2, 'no role other than user and assistant may be relayed');

  const assistant = assistantMessages[0]!.payload.message as Record<string, unknown>;
  assert.match(
    JSON.stringify(assistant),
    new RegExp(FAUX_TEXT),
    'the final assistant message must carry the provider text',
  );
  assert.equal(
    collected.assistantBeforeSettled,
    true,
    'the final assistant message must arrive before the terminal settled state',
  );
  // The plain recipe emits no thinking, so it must emit no phase frame: a phase
  // the model never entered would mislabel the status.
  assert.deepEqual(collected.phases, [], 'a plain-text reply must not emit a phase frame');
  assert.equal(
    collected.streams.map((stream) => stream.text).join(''),
    FAUX_TEXT,
    'the streamed text must be exactly what the faux provider was scripted with',
  );
  assert.deepEqual(
    collected.streams.map((stream) => stream.seq),
    collected.streams.map((_, index) => index + 1),
    'stream seq must be contiguous and start at 1',
  );
});

test('a thinking recipe emits a content-free phase frame before the assistant message', async () => {
  const collected = await drivePrompt({
    PI_DROID_FAUX_MODE: 'thinking',
    PI_DROID_FAUX_THINKING: 'FAUX_REASONING',
  });

  assert.ok(collected.result, 'no command-result arrived for the prompt');
  assert.equal(collected.result.ok, true, `prompt was refused: ${String(collected.result.error)}`);
  assert.ok(collected.settled, 'the agent never settled');

  assert.ok(collected.phases.length > 0, 'a thinking reply must emit a phase frame');
  // The phase frame is content-free by construction: it carries no reasoning.
  for (const phase of collected.phases) {
    assert.deepEqual(Object.keys(phase.payload).sort(), ['kind', 'phase', 'seq']);
    assert.equal(phase.payload.phase, 'thinking');
    assert.equal(JSON.stringify(phase.payload).includes('FAUX_REASONING'), false);
  }
  assert.equal(
    collected.phaseBeforeAssistant,
    true,
    'the phase frame must precede the assistant message it announces',
  );

  const assistantMessages = collected.messages.filter((entry) => entry.role === 'assistant');
  assert.equal(assistantMessages.length, 1, 'exactly one assistant message must be relayed');
  // The thinking content is not streamed; it arrives in full inside the
  // committed message, which is where the transcript renders it from.
  assert.match(
    JSON.stringify(assistantMessages[0]!.payload.message),
    /FAUX_REASONING/,
    'the committed assistant message must carry the thinking body',
  );
  assert.equal(
    collected.streams.map((stream) => stream.text).join(''),
    FAUX_TEXT,
    'phase frames must not pollute the streamed text',
  );
});

// ---------------------------------------------------------------------------
// Step 17 — silence as a real process
// ---------------------------------------------------------------------------

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
