// Shared helpers for the bridge-in-a-real-pi integration tests. Not a test
// file, so the test runner does not collect it. One process per test file means
// the mutable state below is private to each importing file.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { WebSocket } from 'ws';

import { loadOrCreateToken } from '../../src/hub/auth.ts';
import { writeDiscovery } from '../../src/hub/discovery.ts';
import { createHub } from '../../src/hub/hub.ts';
import type { Hub } from '../../src/hub/hub.ts';
import { createTicketStore } from '../../src/hub/pairing.ts';

import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

export const bridgePath = fileURLToPath(new URL('../../extensions/pi-droid-bridge.ts', import.meta.url));
export const harnessPath = fileURLToPath(new URL('../integration/support/faux-provider.ts', import.meta.url));

export const FAUX_TEXT = 'FAUX_OK';
/** The body a `/ping` template expands to. Chosen by the test, asserted verbatim. */
export const TEMPLATE_MARKER = 'TEMPLATE_EXPANDED_OK';
/** The front-matter description the capstone asserts survives onto the wire. */
export const TEMPLATE_DESCRIPTION_SENTINEL = 'TEMPLATE_DESCRIPTION_SENTINEL';
/** pi's built-in slash commands; `getCommands` must never offer one. */
export const BUILTIN_COMMAND_NAMES = [
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
export const BOOT_TIMEOUT_MS = 20_000;
export const STREAM_TIMEOUT_MS = 30_000;
/** Bound on a child's death wait: a hang must fail, never stall `node:test`. */
export const EXIT_TIMEOUT_MS = 30_000;

export let tmpRoot: string;
export let runtimeDir: string;
export let configDir: string;
export let childCwd: string;

export const children: ChildProcess[] = [];
export const hubs: Hub[] = [];
export const viewers: Viewer[] = [];

export function setupBridgeInPi(): void {
  tmpRoot = mkdtempSync(join(tmpdir(), 'pi-droid-in-pi-'));
  runtimeDir = join(tmpRoot, 'runtime');
  configDir = join(tmpRoot, 'config');
  childCwd = join(tmpRoot, 'cwd');
  mkdirSync(runtimeDir, { recursive: true, mode: 0o700 });
  mkdirSync(configDir, { recursive: true, mode: 0o700 });
  mkdirSync(childCwd, { recursive: true });
}

export async function cleanupBridgeInPi(): Promise<void> {
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
}

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

export function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function waitFor(predicate: () => boolean, what: string, timeoutMs: number): Promise<void> {
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
export function waitExit(child: ChildProcess): Promise<void> {
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

export interface PiRun {
  child: ChildProcess;
  stdout(): string;
  stderr(): string;
  send(line: string): void;
  spawnError(): Error | null;
}

export function spawnPi(args: string[], extraEnv: Record<string, string> = {}): PiRun {
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
export async function probeRpcChannel(run: PiRun): Promise<void> {
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
export function completeLines(text: string): string[] {
  const lines = text.split('\n');
  lines.pop();
  return lines.filter((line) => line.trim().length > 0);
}

export function stdoutRecords(text: string): Array<Record<string, unknown>> {
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
export function assertStdoutIsPureJsonl(run: PiRun): void {
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

export function readText(path: string): string | null {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return null;
  }
}

/** True while the pid is alive; `process.kill(pid, 0)` throws ESRCH once dead. */
export function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** A port nobody is listening on right now. */
export function freePort(): Promise<number> {
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

export async function startHub(overrides: Partial<Parameters<typeof createHub>[0]> = {}): Promise<Hub> {
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

export function publishDiscovery(hub: Hub): void {
  writeDiscovery(runtimeDir, {
    agentPort: hub.agentPort,
    viewerPort: hub.viewerPort,
    pid: process.pid,
    startedAt: new Date().toISOString(),
    protocolVersion: PROTOCOL_VERSION,
  });
}

export function writeTokenAt(dir: string, token: string): void {
  const tokenDir = join(dir, 'pi-droid');
  mkdirSync(tokenDir, { recursive: true, mode: 0o700 });
  writeFileSync(join(tokenDir, 'token'), token, { mode: 0o600 });
}

export interface Queue {
  push(message: Record<string, unknown>): void;
  next(timeoutMs: number): Promise<Record<string, unknown>>;
}

/** A FIFO with at most one pending waiter; `ws` delivers in order. */
export function messageQueue(): Queue {
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

export interface Viewer {
  readonly ws: WebSocket;
  send(message: unknown): void;
  tryNext(timeoutMs?: number): Promise<Record<string, unknown> | undefined>;
}

export function connectViewer(port: number, token: string): Promise<Viewer> {
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

export interface SessionSummary {
  sessionId: string;
  label: string;
  agentState: string;
  origin?: string;
}

export async function waitForSession(viewer: Viewer, timeoutMs: number): Promise<SessionSummary> {
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
export async function waitForAppSession(viewer: Viewer, timeoutMs: number): Promise<SessionSummary> {
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
export async function waitForMessage(
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

/**
 * Waits until a replacement is fully observable: the old session going away AND
 * a `sessions` push whose successor names it as replaced. Both are recorded as
 * messages arrive, in whatever order they land — waiting for them in sequence
 * would discard whichever arrived first. The timeout names what was missing,
 * rather than reporting only the second condition's absence.
 */
export async function waitForReplacement(
  viewer: Viewer,
  oldSessionId: string,
  timeoutMs: number,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  let sawGone = false;
  let successor: Record<string, unknown> | undefined;
  while (Date.now() < deadline) {
    const message = await viewer.tryNext(Math.min(1000, Math.max(1, deadline - Date.now())));
    if (message === undefined) continue;
    if (message.type === 'session-gone' && message.sessionId === oldSessionId) {
      sawGone = true;
    }
    if (message.type === 'sessions' && Array.isArray(message.sessions)) {
      const entry = (message.sessions as Array<Record<string, unknown>>).find(
        (candidate) => candidate.replacesSessionId === oldSessionId,
      );
      if (entry !== undefined) successor = entry;
    }
    if (sawGone && successor !== undefined) return successor;
  }
  throw new Error(
    `timed out waiting for ${oldSessionId} to be replaced ` +
      `(saw session-gone: ${sawGone}, saw successor: ${successor !== undefined})`,
  );
}

export interface Collected {
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
export async function collectPrompt(viewer: Viewer, id: string, timeoutMs: number): Promise<Collected> {
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
export async function collectCommandResult(
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

/**
 * Polls `listModels` until both faux models appear. Faux availability is async
 * after native registration (`registerNativeProvider` updates the sync snapshot
 * before the provider is configured), so a single list right after boot is
 * expected to omit both faux models. On timeout it fails naming what it did
 * see — never a quietly shorter list.
 */
export async function waitForBothFauxModels(
  viewer: Viewer,
  sessionId: string,
  timeoutMs: number,
): Promise<Array<Record<string, unknown>>> {
  const deadline = Date.now() + timeoutMs;
  let lastSeen: string[] = [];
  let lastError: string | null = null;
  let attempt = 0;
  while (Date.now() < deadline) {
    const id = `list-models-${attempt}`;
    attempt += 1;
    viewer.send({
      protocolVersion: PROTOCOL_VERSION,
      type: 'command',
      id,
      sessionId,
      name: 'listModels',
    });
    let result: Record<string, unknown>;
    try {
      result = await collectCommandResult(viewer, id, Math.max(1, deadline - Date.now()));
    } catch {
      break; // The deadline expired while waiting for the reply.
    }
    if (result.ok !== true) {
      lastError = String(result.error);
      await delay(50);
      continue;
    }
    const models = Array.isArray(result.models)
      ? (result.models as Array<Record<string, unknown>>)
      : [];
    lastSeen = models.map((model) => `${String(model.provider)}/${String(model.id)}`);
    const has = (provider: string, modelId: string): boolean =>
      models.some((model) => model.provider === provider && model.id === modelId);
    if (has('faux', 'faux-1') && has('faux', 'faux-2')) return models;
    await delay(50);
  }
  throw new Error(
    `listModels never offered both faux models within ${timeoutMs}ms ` +
      `(last error: ${lastError ?? 'none'}; last ids: [${lastSeen.join(', ')}])`,
  );
}

/**
 * Reads relayed messages until the `command-result` for `id` AND a `usage`
 * payload naming `modelId` have both arrived. The bridge emits usage *before*
 * the command-result (the direct `sendUsageEvent` runs inside the dispatch), so
 * a result-first-then-poll helper would discard the very frame it looks for.
 */
export async function collectSwitch(
  viewer: Viewer,
  id: string,
  modelId: string,
  timeoutMs: number,
): Promise<{ result: Record<string, unknown>; usage: Record<string, unknown> }> {
  let result: Record<string, unknown> | null = null;
  let usage: Record<string, unknown> | null = null;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (result !== null && usage !== null) return { result, usage };
    const message = await viewer.tryNext(Math.min(1000, Math.max(1, deadline - Date.now())));
    if (message === undefined) continue;
    if (message.type === 'command-result' && message.id === id) {
      result = message;
      continue;
    }
    if (message.type !== 'event') continue;
    const payload = message.payload as Record<string, unknown> | undefined;
    if (payload?.kind !== 'usage') continue;
    const model = payload.model as Record<string, unknown> | undefined;
    if (model?.id === modelId) usage = payload;
  }
  throw new Error(
    `timed out waiting for the switch: ` +
      `command-result ${result === null ? 'missing' : `ok:${String(result.ok)}`}, ` +
      `usage for ${modelId} ${usage === null ? 'missing' : 'seen'}`,
  );
}

export interface Booted {
  viewer: Viewer;
  session: SessionSummary;
}

/**
 * Boots a hub, a real pi carrying the bridge and the faux harness, subscribes a
 * viewer to its session, and requests history. Children, hubs and viewers are
 * torn down by `afterEach`.
 */
export async function bootPi(
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
export async function drivePrompt(
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
export function messageText(payload: Record<string, unknown>): string {
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
