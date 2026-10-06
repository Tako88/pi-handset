/**
 * #41 — history paging, end to end: a real pi, a real hub and two raw viewers.
 *
 * The PC paging path is split across three modules that only agree by hand:
 * the bridge slices history into pages (`sendHistory` in
 * `extensions/pi-droid-bridge.ts`), the hub routes each answer back to the
 * viewer that asked (`handleHistory` in `src/hub/hub.ts`), and the phone joins
 * the page onto its transcript. A field-name or routing-token drift between two
 * of them leaves every suite green while paging breaks on a real session.
 *
 * This file exercises the whole PC half against a REAL spawned pi carrying the
 * bridge and the faux-provider harness, plus a synthetic v3 session file long
 * enough to need several pages. Two raw `ws` viewers read the wire fields
 * verbatim — the app harness cannot host this (it hardcodes `--no-session`, owns
 * one client and has no second viewer).
 *
 * Scope note: this PC test cannot observe a hub→app field-name drift; that half
 * stays pinned by the hand-written fake in `app/test/client/history_paging_test.dart`.
 *
 * The harness below is a deliberate minimal copy of `bridge-in-pi.test.ts` —
 * copied, not shared, so a passing real-pi test file is not edited for this one.
 */

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, test } from 'node:test';

import { frameText } from '../support/hub-harness.ts';

import { WebSocket } from 'ws';

import { loadOrCreateToken } from '../../src/hub/auth.ts';
import { writeDiscovery } from '../../src/hub/discovery.ts';
import { createHub } from '../../src/hub/hub.ts';
import type { Hub } from '../../src/hub/hub.ts';
import { createTicketStore } from '../../src/hub/pairing.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

const bridgePath = fileURLToPath(new URL('../../extensions/pi-droid-bridge.ts', import.meta.url));
const harnessPath = fileURLToPath(new URL('./support/faux-provider.ts', import.meta.url));

/** Generous: a real pi boots slower than any fake, and this box may be busy. */
const BOOT_TIMEOUT_MS = 20_000;
const STREAM_TIMEOUT_MS = 30_000;
/** Bound on a child's death wait: a hang must fail, never stall `node:test`. */
const EXIT_TIMEOUT_MS = 30_000;

/**
 * The measured fixture: ~2.49 MB; 100 message entries plus 1 markerless
 * `model_change` on disk (a direct `SessionManager.open` probe sees 101
 * context entries spread 32/32/32/5 over four pages). A real RPC boot appends
 * pi's own `thinking_level_change`, so boot-time reality was 102 entries spread
 * 33/31/31/7. The spread is boot-dependent, so nothing below pins it — only that
 * at least two older pages exist.
 */
const FIXTURE_COUNT = 100;

let tmpRoot: string;
let runtimeDir: string;
let configDir: string;
let childCwd: string;

const children: ChildProcess[] = [];
const hubs: Hub[] = [];
const viewers: Viewer[] = [];

beforeEach(() => {
  tmpRoot = mkdtempSync(join(tmpdir(), 'pi-droid-paging-'));
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
    // `timer` is assigned only after `settle` closes over it, so `const` would hit
    // the temporal dead zone if the child exited before the assignment returned.
    // eslint-disable-next-line prefer-const
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
  child.stdout.on('data', (chunk) => {
    stdout += String(chunk);
  });
  child.stderr.on('data', (chunk) => {
    stderr += String(chunk);
  });
  child.on('error', (cause) => {
    error = cause;
  });

  return {
    child,
    stdout: () => stdout,
    stderr: () => stderr,
    send: (line) => child.stdin.write(`${line}\n`),
    spawnError: () => error,
  };
}

/** Waits for a JSONL RPC response on stdout, proving the protocol channel lives. */
async function probeRpcChannel(run: PiRun): Promise<void> {
  run.send(JSON.stringify({ id: 'paging-probe', type: 'get_state' }));
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
      // A corrupt line is a different test's concern; this probe only polls, so
      // it must skip such a line rather than throw from inside a `waitFor`.
    }
  }
  return records;
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
    queue.push(JSON.parse(frameText(data)) as Record<string, unknown>);
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

/** Drains a viewer until `quietMs` of silence, returning everything seen. */
async function drainQuiet(viewer: Viewer, quietMs: number): Promise<Array<Record<string, unknown>>> {
  const seen: Array<Record<string, unknown>> = [];
  for (;;) {
    const message = await viewer.tryNext(quietMs);
    if (message === undefined) return seen;
    seen.push(message);
  }
}

// ---------------------------------------------------------------------------
// Fixture + boot
// ---------------------------------------------------------------------------

/**
 * Writes a synthetic v3 session file whose entries chain by `parentId` in file
 * order, so the leaf is the LAST entry and `buildContextEntries` returns the
 * path root→leaf chronological (measured: first id `00000000`, last `mc`).
 * Every message entry carries an `entry-<n>-` marker the assertions key on, at
 * ~24 KiB each so the file spans several 768 KiB history pages.
 *
 * The trailing `model_change` entry carries NO marker on purpose: it is on the
 * context path (measured), so it exercises the tolerance of `markers()`.
 */
function writeLongSession(path: string, count: number): void {
  const ts = '2026-01-01T00:00:00.000Z';
  const lines: string[] = [
    JSON.stringify({ type: 'session', version: 3, id: 'synthetic-0001', timestamp: ts, cwd: childCwd }),
  ];
  let parentId: string | null = null;
  const filler = 'x'.repeat(24 * 1024); // ~24 KiB/entry
  for (let i = 0; i < count; i++) {
    const id = i.toString(16).padStart(8, '0');
    const text = `entry-${i}-${filler}`; // the marker the assertions key on
    const message =
      i % 2 === 0
        ? { role: 'user', content: text, timestamp: 0 }
        : {
            role: 'assistant',
            content: [{ type: 'text', text }],
            api: 'faux',
            provider: 'faux',
            model: 'faux-1',
            usage: {
              input: 0,
              output: 0,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 0,
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
            },
            stopReason: 'stop',
            timestamp: 0,
          };
    lines.push(JSON.stringify({ type: 'message', id, parentId, timestamp: ts, message }));
    parentId = id;
  }
  lines.push(
    JSON.stringify({
      type: 'model_change',
      id: 'mc',
      parentId,
      timestamp: ts,
      provider: 'faux',
      modelId: 'faux-1',
    }),
  );
  writeFileSync(path, lines.join('\n') + '\n');
}

interface LongBoot {
  hub: Hub;
  run: PiRun;
  sessionPath: string;
  a: Viewer;
  b: Viewer;
  session: SessionSummary;
}

/**
 * Boots a hub with a real pi carrying the bridge and the faux harness, loading
 * the synthetic long session via an ABSOLUTE `--session` path (which takes the
 * `path` branch of `resolveSessionPath`, so there is no global `/` prompt hang).
 * `--no-session` is deliberately ABSENT — it would be checked first and
 * silently discard the fixture. It also connects two raw viewers, so routing
 * can be witnessed. Children, hubs and viewers are torn down by `afterEach`.
 */
async function bootLongSession(count: number): Promise<LongBoot> {
  const { token } = loadOrCreateToken(configDir);
  const hub = await startHub({ token });
  publishDiscovery(hub);

  const sessionPath = join(tmpRoot, 'long-session.jsonl');
  writeLongSession(sessionPath, count);

  const run = spawnPi(
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
      '--session',
      sessionPath,
      '-nc',
    ],
    { PI_DROID_FAUX_TEXT: 'FAUX_OK' },
  );
  assert.equal(run.spawnError(), null, `pi failed to spawn: ${String(run.spawnError())}`);
  // Boot fast-path: if the session file fails to open, pi exits and this probe
  // times out with the stderr tail in its message.
  await probeRpcChannel(run);

  // A viewer that authenticates after the register still receives the session
  // list, so connecting them now is safe.
  const a = await connectViewer(hub.viewerPort, token);
  const b = await connectViewer(hub.viewerPort, token);
  const session = await waitForSession(a, BOOT_TIMEOUT_MS);
  return { hub, run, sessionPath, a, b, session };
}

/**
 * Sends one `history-request` for `cursor` and waits for its answering page
 * (the cursor echoed verbatim). On timeout it re-requests the SAME cursor once
 * and throws an error naming the cursor plus what the retry returned — whether
 * it carried `older` (absent ⇒ the cursor no longer validated and the bridge
 * degraded to a fresh baseline, i.e. pi moved the leaf) and its entry count.
 */
async function requestPage(
  viewer: Viewer,
  sessionId: string,
  cursor: string,
): Promise<Record<string, unknown>> {
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId, cursor });
  try {
    return await waitForMessage(
      viewer,
      (message) =>
        message.type === 'snapshot' && message.sessionId === sessionId && message.cursor === cursor,
      STREAM_TIMEOUT_MS,
    );
  } catch {
    viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId, cursor });
    let diagnostic = 'the retry produced no snapshot either';
    try {
      const retry = await waitForMessage(
        viewer,
        (message) => message.type === 'snapshot' && message.sessionId === sessionId,
        STREAM_TIMEOUT_MS,
      );
      const entries = Array.isArray(retry.entries) ? retry.entries.length : -1;
      diagnostic =
        `the retry produced a snapshot with older=${String(retry.older)} ` +
        `cursor=${String(retry.cursor)} entries=${String(entries)}`;
    } catch {
      // Keep the "no snapshot" default.
    }
    throw new Error(`timed out waiting for the page at cursor ${cursor}: ${diagnostic}`);
  }
}

/**
 * The marker numbers carried by a page, in order. Entries WITHOUT a marker
 * (the fixture's trailing `model_change`, or anything pi itself appends to the
 * leaf path) are filtered out, so the assertions below test the marker
 * SUBSEQUENCE rather than demanding a marker on every entry.
 */
function markers(page: Record<string, unknown>): number[] {
  return (page.entries as unknown[])
    .map((entry) => /entry-(\d+)-/.exec(JSON.stringify(entry)))
    .filter((match): match is RegExpExecArray => match !== null)
    .map((match) => Number(match[1]));
}

// ---------------------------------------------------------------------------
// Step 0 — smoke: a hand-written v3 session loads and pages
// ---------------------------------------------------------------------------

test('a synthetic v3 session file loads and pages', async () => {
  const { run, a, session } = await bootLongSession(FIXTURE_COUNT);
  const sessionId = session.sessionId;

  a.send({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId });
  const baseline = await waitForMessage(
    a,
    (message) => message.type === 'snapshot' && message.sessionId === sessionId,
    STREAM_TIMEOUT_MS,
  );

  const pages: Array<Record<string, unknown>> = [baseline];
  let cursor = typeof baseline.olderCursor === 'string' ? baseline.olderCursor : undefined;
  let guard = 0;
  while (typeof cursor === 'string' && guard < 30) {
    guard += 1;
    const page = await requestPage(a, sessionId, cursor);
    assert.equal(page.cursor, cursor, `step 0 page ${pages.length}: the request cursor must be echoed verbatim`);
    pages.push(page);
    cursor = typeof page.olderCursor === 'string' ? page.olderCursor : undefined;
  }

  const allMarkers = pages.flatMap(markers);
  const unique = Array.from(new Set(allMarkers)).sort((x, y) => x - y);
  const expected = Array.from({ length: FIXTURE_COUNT }, (_, i) => i);
  const report =
    `pages=${pages.length} markers=${allMarkers.length} unique=${unique.length} ` +
    `stderr=${run.stderr().slice(-400)}`;

  assert.equal(typeof baseline.olderCursor, 'string', `the baseline must offer a next-page cursor (${report})`);
  assert.ok(pages.length >= 3, `expected a baseline plus at least two older pages (${report})`);
  assert.equal(allMarkers.length, FIXTURE_COUNT, `every fixture marker must be delivered exactly once (${report})`);
  assert.deepEqual(unique, expected, `every fixture marker must be present (${report})`);
});

// ---------------------------------------------------------------------------
// Step 9 — the end-to-end paging walk and routing witness
// ---------------------------------------------------------------------------

test('history paging walks a long session back one page at a time and routes each reply to its asker', async () => {
  const { run, a, b, session } = await bootLongSession(FIXTURE_COUNT);
  assert.equal(session.origin, 'pc', 'the fixture session must be a pc-origin session');
  const sessionId = session.sessionId;

  // Subscription state is NOT load-bearing for routing — `handleHistoryRequest`
  // never checks it. Subscribing both is the real app's behaviour, and is
  // deliberately not what makes the routing assertion below pass.
  a.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId });
  b.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId });

  // ---- baseline -----------------------------------------------------------
  a.send({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId });
  const baseline = await waitForMessage(
    a,
    (message) => message.type === 'snapshot' && message.sessionId === sessionId,
    STREAM_TIMEOUT_MS,
  );
  assert.equal(baseline.truncated, true, 'sub-baseline: a long session must report omitted older entries');
  assert.ok(!('older' in baseline), 'sub-baseline: a baseline is not an older page');
  assert.ok(!('cursor' in baseline), 'sub-baseline: no cursor was requested, so none may be echoed');
  assert.equal(typeof baseline.olderCursor, 'string', 'sub-baseline: the baseline must offer a next-page cursor');
  assert.equal(typeof baseline.lastSeq, 'number', 'sub-baseline: the hub must stamp lastSeq');
  assert.equal(typeof baseline.agentState, 'string', 'sub-baseline: the hub must stamp agentState');

  // ---- page loop ----------------------------------------------------------
  const pages: Array<Record<string, unknown>> = [baseline];
  let cursor: string | undefined = baseline.olderCursor as string;
  let guard = 0;
  while (typeof cursor === 'string' && guard < 30) {
    guard += 1;
    const page = await requestPage(a, sessionId, cursor);
    assert.equal(page.older, true, `sub-page ${pages.length}: a requested page must be flagged older`);
    assert.equal(page.cursor, cursor, `sub-page ${pages.length}: the request cursor must be echoed verbatim`);
    assert.ok(
      Array.isArray(page.entries) && page.entries.length > 0,
      `sub-page ${pages.length}: a page must carry entries`,
    );
    pages.push(page);
    cursor = typeof page.olderCursor === 'string' ? page.olderCursor : undefined;
  }
  assert.ok(
    pages.length - 1 >= 2,
    `sub-page-count: expected at least two older pages, saw ${pages.length - 1} ` +
      `(stderr=${run.stderr().slice(-400)})`,
  );

  // Every page but the last must still have older entries behind it.
  for (let k = 1; k + 1 < pages.length; k++) {
    assert.equal(
      pages[k].truncated,
      true,
      `sub-page ${k}: a non-final older page must report omitted older entries`,
    );
  }

  // ---- last page ----------------------------------------------------------
  const last = pages[pages.length - 1];
  assert.equal(last.older, true, 'sub-last: the final page is a genuinely older page');
  assert.ok(!('olderCursor' in last), 'sub-last: the final page must report no more');
  assert.equal(last.truncated, false, 'sub-last: the final page reached the beginning');

  // ---- contiguity / no duplicates ----------------------------------------
  for (let k = 0; k < pages.length; k++) {
    const pageMarkers = markers(pages[k]);
    for (let i = 1; i < pageMarkers.length; i++) {
      assert.equal(pageMarkers[i], pageMarkers[i - 1] + 1, `sub-contiguity: page ${k} markers must ascend by exactly 1`);
    }
  }
  for (let k = 0; k + 1 < pages.length; k++) {
    const older = markers(pages[k + 1]);
    const newer = markers(pages[k]);
    assert.equal(
      Math.max(...older),
      Math.min(...newer) - 1,
      `sub-contiguity: page ${k + 1} must continue immediately below page ${k}`,
    );
  }
  assert.equal(Math.min(...markers(last)), 0, 'sub-contiguity: the last page must reach entry 0');

  const totalMarkers = pages.reduce((sum, page) => sum + markers(page).length, 0);
  const union = Array.from(new Set(pages.flatMap(markers))).sort((x, y) => x - y);
  const expected = Array.from({ length: FIXTURE_COUNT }, (_, i) => i);
  assert.equal(totalMarkers, FIXTURE_COUNT, 'sub-union: no marker may be delivered twice');
  assert.deepEqual(union, expected, 'sub-union: every fixture entry must be delivered exactly once');

  // ---- routing ------------------------------------------------------------
  // A snapshot is a response to a request; B never asked, so it must never see
  // one. B does legitimately receive `sessions` broadcasts, so drain until
  // 300 ms of quiet and then look only for snapshots. The hub sends to the
  // request group synchronously, so a misroute is already queued by now.
  const bSaw = await drainQuiet(b, 300);
  assert.deepEqual(
    bSaw.filter((message) => message.type === 'snapshot'),
    [],
    'sub-routing: viewer B must not receive snapshots it never requested',
  );
});
