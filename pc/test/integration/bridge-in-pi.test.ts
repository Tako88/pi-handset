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
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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
import { createSpawner } from '../../src/hub/spawner.ts';
import type { Spawner } from '../../src/hub/spawner.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

const bridgePath = fileURLToPath(new URL('../../extensions/pi-droid-bridge.ts', import.meta.url));
const harnessPath = fileURLToPath(new URL('./support/faux-provider.ts', import.meta.url));

const FAUX_TEXT = 'FAUX_OK';
/** The body a `/ping` template expands to. Chosen by the test, asserted verbatim. */
const TEMPLATE_MARKER = 'TEMPLATE_EXPANDED_OK';
/** The front-matter description the capstone asserts survives onto the wire. */
const TEMPLATE_DESCRIPTION_SENTINEL = 'TEMPLATE_DESCRIPTION_SENTINEL';
/** pi's built-in slash commands; `getCommands` must never offer one. */
const BUILTIN_COMMAND_NAMES = [
  'settings',
  'model',
  'tree',
  'thinking',
  'scoped-models',
  'export',
  'import',
  'share',
  'bug',
  'copy',
  'name',
  'session',
  'changelog',
  'hotkeys',
  'fork',
  'clone',
  'trust',
  'login',
  'logout',
  'new',
  'compact',
  'resume',
  'reload',
  'quit',
];
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

function readText(path: string): string | null {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return null;
  }
}

/** True while the pid is alive; `process.kill(pid, 0)` throws ESRCH once dead. */
function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
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
  origin?: string;
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

/** Waits for a `sessions` push carrying an `origin:'app'` entry. */
async function waitForAppSession(viewer: Viewer, timeoutMs: number): Promise<SessionSummary> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const message = await viewer.tryNext(Math.min(1000, Math.max(1, deadline - Date.now())));
    if (message === undefined) continue;
    if (message.type !== 'sessions' || !Array.isArray(message.sessions)) continue;
    const entry = (message.sessions as Array<Record<string, unknown>>).find(
      (session) => session.origin === 'app',
    );
    if (entry !== undefined) return entry as unknown as SessionSummary;
  }
  throw new Error('timed out waiting for an app-origin session to register');
}

/** Reads relayed messages until one matches, rejecting after a bound. */
async function waitForMessage(
  viewer: Viewer,
  predicate: (message: Record<string, unknown>) => boolean,
  timeoutMs: number,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const message = await viewer.tryNext(Math.min(1000, Math.max(1, deadline - Date.now())));
    if (message === undefined) continue;
    if (predicate(message)) return message;
  }
  throw new Error('timed out waiting for a matching message');
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
  /** Context-usage readings, in arrival order. */
  usages: Array<{ tokens: number | null; contextWindow: number }>;
  /** True when a reading arrived before any turn ran — i.e. on attach. */
  attachUsage: boolean;
  /** True when a reading arrived after the terminal state, i.e. the turn refresh. */
  settledUsage: boolean;
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
    usages: [],
    attachUsage: false,
    settledUsage: false,
    result: null,
  };
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    // The turn's reading lands immediately after the terminal state, so settling
    // alone is not the end of what this test asserts.
    if (collected.result !== null && collected.settled && collected.settledUsage) break;
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
    } else if (payload.kind === 'usage') {
      collected.usages.push({
        tokens: payload.tokens as number | null,
        contextWindow: payload.contextWindow as number,
      });
      if (!collected.running) collected.attachUsage = true;
      if (collected.settled) collected.settledUsage = true;
    }
  }
  return collected;
}

/**
 * Reads relayed messages until the `command-result` for `id` arrives. Absence is
 * a real failure, not a quietly shorter list.
 */
async function collectCommandResult(
  viewer: Viewer,
  id: string,
  timeoutMs: number,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const message = await viewer.tryNext(Math.min(1000, Math.max(1, deadline - Date.now())));
    if (message === undefined) continue;
    if (message.type === 'command-result' && message.id === id) return message;
  }
  throw new Error(`timed out waiting for the command-result for ${id}`);
}

interface Booted {
  viewer: Viewer;
  session: SessionSummary;
}

/**
 * Boots a hub, a real pi carrying the bridge and the faux harness, subscribes a
 * viewer to its session, and requests history. Children, hubs and viewers are
 * torn down by `afterEach`.
 */
async function bootPi(
  extraEnv: Record<string, string> = {},
  extraArgs: string[] = [],
): Promise<Booted> {
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
      ...extraArgs,
    ],
    { PI_DROID_FAUX_TEXT: FAUX_TEXT, ...extraEnv },
  );

  const viewer = await connectViewer(hub.viewerPort, token);
  const session = await waitForSession(viewer, BOOT_TIMEOUT_MS);
  assert.ok(session.sessionId.length > 0, 'the register must carry a session id');
  assert.ok(session.label.length > 0, 'the register must produce a viewer-safe label');
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: session.sessionId });
  // The real app asks for history the moment it subscribes, and that replay is
  // where an attaching phone learns the context usage.
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: session.sessionId,
  });

  return { viewer, session };
}

/**
 * Boots a hub, a real pi carrying the bridge and the faux harness, and drives
 * one prompt end to end. Returns everything the hub relayed to the viewer.
 * Children, hubs and viewers are torn down by `afterEach`.
 */
async function drivePrompt(
  extraEnv: Record<string, string> = {},
  extraArgs: string[] = [],
  promptText = 'say the word',
): Promise<Collected> {
  const { viewer, session } = await bootPi(extraEnv, extraArgs);

  const id = 'prompt-1';
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId: session.sessionId,
    name: 'prompt',
    args: { text: promptText },
  });

  return collectPrompt(viewer, id, STREAM_TIMEOUT_MS);
}

/**
 * The text of a relayed `message` payload, for either content shape pi uses: a
 * bare string, or an array of typed parts.
 */
function messageText(payload: Record<string, unknown>): string {
  const message = payload.message as Record<string, unknown> | undefined;
  const content = message?.content;
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .map((part) => (part as { text?: unknown }).text)
    .filter((text): text is string => typeof text === 'string')
    .join('');
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

  // Context usage rides the history replay, so a phone that attaches before any
  // turn has a number to show, and then refreshes when the turn settles.
  assert.ok(
    collected.attachUsage,
    'a context-usage reading must arrive on attach, before any turn runs',
  );
  assert.ok(collected.settledUsage, 'the reading must refresh after the turn');
  const latest = collected.usages.at(-1)!;
  assert.equal(typeof latest.tokens, 'number', 'a settled turn must report a token count');
  assert.ok((latest.tokens ?? 0) > 0, 'the token count must be positive after a real reply');
  assert.ok(latest.contextWindow > 0, 'the model must report a context window');

  // Per-role counts, not a single total. M2 added a THIRD relayed role,
  // `toolResult`; this recipe runs no tools, so its count must be zero — an
  // accidental relay (or a recipe leak) may not pass silently.
  const byRole = (role: string) =>
    collected.messages.filter((entry) => entry.role === role);
  assert.equal(byRole('user').length, 1, 'exactly one user message must be relayed');
  assert.equal(byRole('assistant').length, 1, 'exactly one assistant message must be relayed');
  assert.equal(byRole('toolResult').length, 0, 'a plain reply runs no tools');
  assert.equal(collected.messages.length, 2, 'no role other than user and assistant may be relayed here');

  const assistant = byRole('assistant')[0]!.payload.message as Record<string, unknown>;
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
    // The whole stream channel must be contiguous, not just its text half:
    // reasoning deltas consume seqs too, so a text-only view of the sequence
    // would show gaps that are not really gaps. Compared in ARRIVAL order —
    // sorting would wave through out-of-order delivery on an ordered channel.
    [...collected.streams, ...collected.phases].map((frame) => frame.seq),
    [...collected.streams, ...collected.phases].map((_frame, index) => index + 1),
    'stream seq must be contiguous and start at 1',
  );
});

test('a thinking recipe streams the reasoning before the assistant message', async () => {
  const collected = await drivePrompt({
    PI_DROID_FAUX_MODE: 'thinking',
    PI_DROID_FAUX_THINKING: 'FAUX_REASONING',
  });

  assert.ok(collected.result, 'no command-result arrived for the prompt');
  assert.equal(collected.result.ok, true, `prompt was refused: ${String(collected.result.error)}`);
  assert.ok(collected.settled, 'the agent never settled');

  assert.ok(collected.phases.length > 0, 'a thinking reply must emit the liveness phase frame');
  for (const phase of collected.phases) {
    assert.equal(phase.payload.phase, 'thinking');
  }
  // The first frame of the phase carries no text: it exists to label
  // "Thinking…" before the first chunk lands. Later frames carry the chunks.
  assert.equal(
    collected.phases[0]!.payload.text,
    undefined,
    'the liveness frame must be content-free',
  );
  assert.equal(
    collected.phaseBeforeAssistant,
    true,
    'the phase frame must precede the assistant message it announces',
  );

  // The reasoning itself now streams, one chunk per frame, tagged with its phase
  // so the app can route it away from the reply. This is what the faux provider
  // is scripted with (`faux-provider.ts` opts into `reasoning: true`).
  const streamedReasoning = collected.phases
    .filter((phase) => typeof phase.payload.text === 'string')
    .map((phase) => phase.payload.text as string)
    .join('');
  assert.equal(
    streamedReasoning,
    'FAUX_REASONING',
    'the reasoning must arrive in full, chunk by chunk, before the commit',
  );

  const assistantMessages = collected.messages.filter((entry) => entry.role === 'assistant');
  assert.equal(assistantMessages.length, 1, 'exactly one assistant message must be relayed');
  assert.equal(
    collected.messages.filter((entry) => entry.role === 'toolResult').length,
    0,
    'the thinking recipe runs no tools',
  );
  // The committed message stays authoritative, and is what the transcript
  // renders the durable thinking block from.
  assert.match(
    JSON.stringify(assistantMessages[0]!.payload.message),
    /FAUX_REASONING/,
    'the committed assistant message must carry the thinking body',
  );
  assert.equal(
    collected.streams.map((stream) => stream.text).join(''),
    FAUX_TEXT,
    'reasoning frames must not pollute the streamed reply text',
  );
});

test('a tools recipe relays a toolResult whose toolCallId matches the call', async () => {
  const toolPath = join(childCwd, 'faux-tool.txt');
  writeFileSync(toolPath, 'FAUX_TOOL_CONTENT\nline two\n', { flag: 'w' });

  const collected = await drivePrompt({
    PI_DROID_FAUX_MODE: 'tools',
    PI_DROID_FAUX_TOOL_PATH: toolPath,
  });

  assert.ok(collected.result, 'no command-result arrived for the prompt');
  assert.equal(collected.result.ok, true, `prompt was refused: ${String(collected.result.error)}`);
  assert.ok(collected.settled, 'the agent never settled');

  // Per-role counts, not a single total. The tools recipe adds a THIRD relayed
  // role: `toolResult`. Count it explicitly, or a dropped result passes as
  // cleanly as a double-emitted one.
  const byRole = (role: string) =>
    collected.messages.filter((entry) => entry.role === role);
  assert.equal(byRole('user').length, 1, 'exactly one user message must be relayed');
  assert.equal(
    byRole('assistant').length,
    2,
    'the tool-call turn and the final reply are two assistant messages',
  );
  assert.equal(
    byRole('toolResult').length,
    1,
    `exactly one toolResult must be relayed, got roles ${collected.messages
      .map((entry) => entry.role)
      .join(',')}`,
  );
  assert.equal(collected.messages.length, 4, 'no role other than user, assistant and toolResult may be relayed');

  // The call is in the first assistant message; the result names the same id
  // and carries the tool's output.
  const callMessage = JSON.stringify(byRole('assistant')[0]!.payload.message);
  assert.match(callMessage, /"type":"toolCall"/);
  assert.match(callMessage, /"id":"call-1"/);
  const result = byRole('toolResult')[0]!.payload.message as Record<string, unknown>;
  assert.equal(result.toolCallId, 'call-1', 'the result must pair with the call by id');
  assert.equal(result.toolName, 'read');
  assert.equal(result.isError, false);
  assert.match(
    JSON.stringify(result.content),
    /FAUX_TOOL_CONTENT/,
    'the result content must carry the tool output',
  );
  assert.match(
    JSON.stringify(byRole('assistant')[1]!.payload.message),
    new RegExp(FAUX_TEXT),
    'the final assistant message must carry the provider text',
  );
});

// ---------------------------------------------------------------------------
// Slash commands
// ---------------------------------------------------------------------------

test('a slash command from the phone runs as a command, not as literal text', async () => {
  // `/ping` is loaded by explicit path, so this needs no project trust and does
  // not depend on the user's real agent directory.
  const templatePath = join(tmpRoot, 'ping.md');
  writeFileSync(
    templatePath,
    [
      '---',
      'description: Marker template for the slash-command witness',
      '---',
      TEMPLATE_MARKER,
      '',
    ].join('\n'),
  );

  const collected = await drivePrompt({}, ['--prompt-template', templatePath], '/ping');

  assert.equal(collected.result?.ok, true, 'the prompt was refused');
  const user = collected.messages.find((entry) => entry.role === 'user');
  assert.ok(user, 'no user message was relayed');

  // What lands in the session is the template body, not the typed command. The
  // failure this pins is the literal: `/ping` injected verbatim, leaving the
  // model to interpret a command name as prose.
  const text = messageText(user.payload);
  assert.ok(
    text.includes(TEMPLATE_MARKER),
    `the template was not expanded; the user message was ${JSON.stringify(text)}`,
  );
  assert.ok(!text.includes('/ping'), 'the raw command text was sent verbatim');
});

test("a real pi's command list reaches the viewer", async () => {
  // The description lives in front-matter and is deliberately one distinctive
  // string: the assertion is on the front-matter value, not on pi's body-first-
  // line fallback (truncated to 60 chars).
  const templatePath = join(tmpRoot, 'ping.md');
  writeFileSync(
    templatePath,
    [
      '---',
      `description: '${TEMPLATE_DESCRIPTION_SENTINEL}'`,
      '---',
      TEMPLATE_MARKER,
      '',
    ].join('\n'),
  );

  const { viewer, session } = await bootPi({}, ['--prompt-template', templatePath]);
  const id = 'list-1';
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId: session.sessionId,
    name: 'listCommands',
  });

  const result = await collectCommandResult(viewer, id, STREAM_TIMEOUT_MS);
  assert.equal(result.ok, true, `listCommands was refused: ${String(result.error)}`);
  const commands = result.commands as Array<{ name: string; description?: string }>;
  assert.ok(Array.isArray(commands), 'the result must carry a command list');

  // O3: a CLI template's front-matter description survives as the entry's
  // description. Not an exact list length: discovered skills may add entries.
  const ping = commands.find((command) => command.name === 'ping');
  assert.ok(
    ping,
    `the list must contain the CLI template 'ping', got ${commands
      .map((command) => command.name)
      .join(', ')}`,
  );
  assert.equal(
    ping.description,
    TEMPLATE_DESCRIPTION_SENTINEL,
    'the template front-matter description must travel as the command description',
  );

  // O2: pi's built-ins live in a separate constant that `getCommands` never
  // references, so no built-in may appear in the list.
  const offered = new Set(commands.map((command) => command.name));
  for (const name of BUILTIN_COMMAND_NAMES) {
    assert.ok(!offered.has(name), `built-in ${name} must never be offered`);
  }
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

// ---------------------------------------------------------------------------
// Step 22 — the capstone: bare production args, configured-extension discovery
// ---------------------------------------------------------------------------

test('a spawned bare pi registers, prompts and dies on kill-session', async () => {
  // The bridge and the faux harness are loaded through *configured-extension
  // discovery* — the same mechanism production uses — with no `-e`. The faux
  // provider is the declared carve-out; the registration path is production.
  const { token } = loadOrCreateToken(configDir);
  const agentDir = join(tmpRoot, 'agent');
  mkdirSync(agentDir, { recursive: true, mode: 0o700 });
  writeFileSync(
    join(agentDir, 'settings.json'),
    JSON.stringify({
      defaultProvider: 'faux',
      defaultModel: 'faux-1',
      extensions: [
        fileURLToPath(new URL('../../extensions', import.meta.url)),
        harnessPath,
      ],
    }),
  );

  const real = createSpawner({
    env: {
      ...process.env,
      PI_DROID_RUNTIME_DIR: runtimeDir,
      XDG_CONFIG_HOME: configDir,
      PI_CODING_AGENT_DIR: agentDir,
      PI_DROID_FAUX_TEXT: FAUX_TEXT,
    },
  });
  const pids: number[] = [];
  // Wrap the real spawner only to observe the pid it hands back; every
  // behaviour is the production one.
  const spawner: Spawner = {
    spawn: async (options) => {
      const pid = await real.spawn(options);
      pids.push(pid);
      return pid;
    },
    owns: (pid) => real.owns(pid),
    confirm: (pid) => real.confirm(pid),
    kill: (pid) => real.kill(pid),
    close: () => real.close(),
  };

  const hub = await startHub({ token, spawner });
  publishDiscovery(hub);

  const viewer = await connectViewer(hub.viewerPort, token);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });

  const session = await waitForAppSession(viewer, BOOT_TIMEOUT_MS);
  assert.ok(session.sessionId.length > 0, 'the spawned pi must register a session id');
  assert.equal(session.origin, 'app', 'the spawner-owned pid must derive origin app');

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'subscribe',
    sessionId: session.sessionId,
  });
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: session.sessionId,
  });

  const id = 'prompt-1';
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId: session.sessionId,
    name: 'prompt',
    args: { text: 'say the word' },
  });

  const collected = await collectPrompt(viewer, id, STREAM_TIMEOUT_MS);
  assert.ok(collected.result, 'no command-result arrived for the prompt');
  assert.equal(
    collected.result.ok,
    true,
    `prompt was refused: ${String(collected.result.error)}`,
  );
  assert.ok(collected.settled, 'the spawned agent never settled');
  assert.equal(
    collected.streams.map((stream) => stream.text).join(''),
    FAUX_TEXT,
    'the spawned pi must stream the faux provider reply',
  );

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'kill-1',
    sessionId: session.sessionId,
  });
  const killResult = await waitForMessage(
    viewer,
    (message) => message.type === 'command-result' && message.id === 'kill-1',
    5000,
  );
  assert.equal(killResult.ok, true, `kill was refused: ${String(killResult.error)}`);

  await waitForMessage(
    viewer,
    (message) => message.type === 'session-gone' && message.sessionId === session.sessionId,
    5000,
  );
  assert.equal(pids.length, 1, 'exactly one child was spawned');
  await waitFor(
    () => !alive(pids[0]!),
    'the spawned process group to be gone after the kill',
    5000,
  );
});
