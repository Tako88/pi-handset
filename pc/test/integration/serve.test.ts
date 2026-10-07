import assert from 'node:assert/strict';
import { afterEach, beforeEach, test } from 'node:test';
import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { createServer } from 'node:net';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { WebSocket } from 'ws';

import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';
import { acquireLock } from '../../src/hub/discovery.ts';
import { abortStartup, finishShutdown } from '../../src/cli/serve.ts';
import {
  TITLE_REWRITER_ARGV_ENV,
  TITLE_REWRITER_PID_ENV,
  writeTitleRewriter,
} from './title_rewriter.ts';
import { frameText } from '../support/hub-harness.ts';

const pcRoot = fileURLToPath(new URL('../..', import.meta.url));
const serveEntry = fileURLToPath(new URL('../../src/cli/serve.ts', import.meta.url));
const mainEntry = fileURLToPath(new URL('../../src/cli/main.ts', import.meta.url));

/** Bound on a child's exit; a child that will not die is SIGKILLed. */
const EXIT_TIMEOUT_MS = 10_000;

let runtimeDir: string;
let configDir: string;
let spawned: ChildProcess[];
let sockets: WebSocket[];
const scratchShimDirs: string[] = [];

beforeEach(() => {
  runtimeDir = mkdtempSync(join(tmpdir(), 'pi-handset-serve-'));
  // The supervisor loads the real token; point its config at a temp dir so the
  // suite never touches the user's `~/.config`.
  configDir = mkdtempSync(join(tmpdir(), 'pi-handset-serve-config-'));
  spawned = [];
  sockets = [];
});

afterEach(() => {
  // Never leave orphans: kill anything still running, even on a failed test.
  for (const socket of sockets) {
    socket.terminate();
  }
  for (const child of spawned) {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGKILL');
    }
  }
  rmSync(runtimeDir, { recursive: true, force: true });
  rmSync(configDir, { recursive: true, force: true });
  for (const dir of scratchShimDirs) rmSync(dir, { recursive: true, force: true });
  scratchShimDirs.length = 0;
});

/** True while the pid is alive; `process.kill(pid, 0)` throws ESRCH once dead. */
function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

interface ServeHandle {
  child: ChildProcess;
  stdout: () => string;
  stderr: () => string;
}

function startServe(
  args: string[] = [],
  extraEnv: Record<string, string> = {},
  entry = serveEntry,
): ServeHandle {
  const child = spawn(process.execPath, [entry, ...args], {
    cwd: pcRoot,
    env: {
      ...process.env,
      PI_HANDSET_RUNTIME_DIR: runtimeDir,
      XDG_CONFIG_HOME: configDir,
      ...extraEnv,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  spawned.push(child);
  let stdout = '';
  child.stdout.on('data', (chunk) => {
    stdout += String(chunk);
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => {
    stderr += String(chunk);
  });
  return { child, stdout: () => stdout, stderr: () => stderr };
}

function discoveryFile(): string {
  return join(runtimeDir, 'pi-handset', 'supervisor.json');
}

function lockFile(): string {
  return join(runtimeDir, 'pi-handset', 'supervisor.lock');
}

function readPid(): number | null {
  try {
    const parsed = JSON.parse(readFileSync(discoveryFile(), 'utf8')) as { pid?: number };
    return parsed.pid ?? null;
  } catch {
    return null;
  }
}

function readRecord(): Record<string, unknown> | null {
  try {
    return JSON.parse(readFileSync(discoveryFile(), 'utf8')) as Record<string, unknown>;
  } catch {
    return null;
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

/**
 * Waits for a spawned child to be gone. Resolves on the first of `exit`,
 * `close` or `error`: a failed spawn (ENOENT/EACCES) emits `error` and never a
 * guaranteed `exit`, so waiting on `exit` alone would hang `node:test` forever
 * (there is no default timeout). The wait is bounded too — a child that will
 * not die is SIGKILLed and the promise rejects naming its pid and command, so a
 * hang inside `afterEach` cannot block every subsequent test in the file.
 */
function waitExit(child: ChildProcess): Promise<{ code: number | null; signal: string | null }> {
  return new Promise((resolve, reject) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve({ code: child.exitCode, signal: child.signalCode });
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
      resolve({ code: child.exitCode, signal: child.signalCode });
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

async function waitFor(
  predicate: () => boolean,
  what: string,
  timeoutMs = 5000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** A pid that is guaranteed to be dead: spawn and reap a short-lived child. */
async function deadPid(): Promise<number> {
  const child = spawn(process.execPath, ['-e', 'process.exit(0)']);
  const pid = child.pid!;
  await new Promise<void>((resolve) => child.once('exit', () => resolve()));
  return pid;
}

/** Waits until either child exits, or throws if neither does within the bound. */
async function waitForAnyExit(
  a: ChildProcess,
  b: ChildProcess,
  timeoutMs = 5000,
): Promise<ChildProcess> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (a.exitCode !== null || a.signalCode !== null) return a;
    if (b.exitCode !== null || b.signalCode !== null) return b;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error('neither serve exited; mutual exclusion failed');
}

/** Spawns serve, waits for it to exit, and returns its code and stderr. */
async function runServeToExit(
  args: string[],
  extraEnv: Record<string, string> = {},
): Promise<{ code: number | null; stderr: string }> {
  const serve = startServe(args, extraEnv);
  const { code } = await waitExit(serve.child);
  return { code, stderr: serve.stderr() };
}

/** The pairing codes printed so far, in print order (`XXXX-XXXX`). */
function printedCodes(out: string): string[] {
  return out.match(/\b[0-9A-Z]{4}-[0-9A-Z]{4}\b/g) ?? [];
}

/** Spawns serve and waits until it is listening (discovery file published). */
async function startReadyServe(port: number): Promise<ServeHandle> {
  const serve = startServe(['--port', String(port)]);
  await waitFor(() => readPid() === serve.child.pid, 'the discovery file');
  return serve;
}

/** Runs `main.ts pair` in this runtime dir and returns its output and code. */
async function runPairProcess(): Promise<{ code: number | null; stdout: string; stderr: string }> {
  const child = spawn(process.execPath, [mainEntry, 'pair'], {
    cwd: pcRoot,
    env: { ...process.env, PI_HANDSET_RUNTIME_DIR: runtimeDir, XDG_CONFIG_HOME: configDir },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  spawned.push(child);
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => {
    stdout += String(chunk);
  });
  child.stderr.on('data', (chunk) => {
    stderr += String(chunk);
  });
  const { code } = await waitExit(child);
  return { code, stdout, stderr };
}

/**
 * True when the hub accepts `code`. A rejected ticket closes the viewer without
 * a `paired` reply; the first settle wins.
 */
async function acceptsTicket(port: number, code: string): Promise<boolean> {
  const socket = await connectViewer(port);
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (accepted: boolean): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(accepted);
    };
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        reject(new Error('timed out waiting for the hub to answer the ticket'));
      }
    }, 5000);
    socket.on('message', (data) => {
      const message = JSON.parse(frameText(data)) as Record<string, unknown>;
      if (message.type === 'paired') finish(true);
    });
    socket.on('close', () => finish(false));
    socket.on('error', () => finish(false));
    const hello = JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'hello',
      ticket: code,
    });
    // A bad ticket only closes after `maxAuthAttempts` (3); a valid one pairs
    // on the first.
    socket.send(hello);
    setTimeout(() => socket.send(hello), 30);
    setTimeout(() => socket.send(hello), 60);
  });
}

/** Opens the viewer socket; the caller must terminate it (afterEach does). */
function connectViewer(port: number): Promise<WebSocket> {
  const socket = new WebSocket(`ws://127.0.0.1:${port}`);
  sockets.push(socket);
  return new Promise((resolve, reject) => {
    socket.once('open', () => resolve(socket));
    socket.once('error', reject);
  });
}

/** Resolves with the next `paired` reply, rejecting after a bound. */
function awaitPaired(socket: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('timed out waiting for paired')),
      5000,
    );
    socket.on('message', (data) => {
      const message = JSON.parse(frameText(data)) as Record<string, unknown>;
      if (message.type === 'paired') {
        clearTimeout(timer);
        resolve(message);
      }
    });
  });
}

/** Exchanges a code for the token over a fresh viewer connection. */
async function redeem(port: number, code: string): Promise<Record<string, unknown>> {
  const socket = await connectViewer(port);
  const paired = awaitPaired(socket);
  socket.send(JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'hello', ticket: code }));
  return paired;
}

/** The token serve persisted in the temp config dir. */
function persistedToken(): string {
  return readFileSync(join(configDir, 'pi-handset', 'token'), 'utf8').trim();
}

/** Authenticates a viewer with the persisted token and drains its auth push. */
async function authViewer(port: number): Promise<WebSocket> {
  const socket = await connectViewer(port);
  const ready = new Promise<void>((resolve) => {
    socket.on('message', (data) => {
      const message = JSON.parse(frameText(data)) as Record<string, unknown>;
      if (message.type === 'sessions') resolve();
    });
  });
  socket.send(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'hello',
      token: persistedToken(),
    }),
  );
  await ready;
  return socket;
}

/** Resolves with the next message matching `type`, rejecting after a bound. */
function awaitMessage(
  socket: WebSocket,
  type: string,
  timeoutMs = 5000,
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`timed out waiting for ${type}`)),
      timeoutMs,
    );
    socket.on('message', (data) => {
      const message = JSON.parse(frameText(data)) as Record<string, unknown>;
      if (message.type === type) {
        clearTimeout(timer);
        resolve(message);
      }
    });
  });
}

test('serve announces the pair command', async () => {
  const port = await freePort();
  const serve = startServe(['--port', String(port)]);
  await waitFor(() => readPid() === serve.child.pid, 'the discovery file');

  await waitFor(
    () => serve.stdout().includes('main.ts pair'),
    'the startup pairing hint',
  );
  assert.match(serve.stdout(), /main\.ts pair/);

  const exited = waitExit(serve.child);
  serve.child.kill('SIGTERM');
  await exited;
});

test('SIGUSR1 prints a pairing code that the hub actually redeems', async () => {
  const port = await freePort();
  const serve = await startReadyServe(port);

  serve.child.kill('SIGUSR1');
  await waitFor(() => printedCodes(serve.stdout()).length === 1, 'the pairing code');
  const code = printedCodes(serve.stdout())[0];

  const paired = await redeem(port, code);
  assert.equal(paired.token, persistedToken(), 'the printed code must exchange for the token');

  const exited = waitExit(serve.child);
  serve.child.kill('SIGTERM');
  await exited;
});

test('SIGUSR1 twice prints a second code that also redeems', async () => {
  const port = await freePort();
  const serve = await startReadyServe(port);

  serve.child.kill('SIGUSR1');
  await waitFor(() => printedCodes(serve.stdout()).length === 1, 'the first code');
  serve.child.kill('SIGUSR1');
  await waitFor(() => printedCodes(serve.stdout()).length === 2, 'the second code');

  const [first, second] = printedCodes(serve.stdout());
  assert.notEqual(first, second, 'a re-issue must mint a fresh code');

  const paired = await redeem(port, second);
  assert.equal(paired.token, persistedToken(), 'the second code must also exchange');

  const exited = waitExit(serve.child);
  serve.child.kill('SIGTERM');
  await exited;
});

test('serve writes a 0600 discovery file with both ports and removes it on SIGTERM', async () => {
  const port = await freePort();
  const first = startServe(['--port', String(port)]);

  await waitFor(() => readPid() === first.child.pid, 'the discovery file');
  assert.equal(statSync(discoveryFile()).mode & 0o777, 0o600);
  assert.equal(statSync(join(runtimeDir, 'pi-handset')).mode & 0o777, 0o700);

  const raw = readRecord()!;
  assert.equal(raw.pid, first.child.pid);
  assert.equal(raw.viewerPort, port);
  assert.ok(Number.isSafeInteger(raw.agentPort) && (raw.agentPort as number) > 0);
  assert.notEqual(raw.agentPort, raw.viewerPort, 'the agent listener is ephemeral');
  assert.equal(raw.protocolVersion, PROTOCOL_VERSION);
  assert.equal(typeof raw.startedAt, 'string');

  const exited = waitExit(first.child);
  first.child.kill('SIGTERM');
  await exited;

  assert.equal(existsSync(discoveryFile()), false, 'the file is removed on close');
});

test('serve with --no-lan still publishes both ports', async () => {
  const port = await freePort();
  const hub = startServe(['--port', String(port), '--no-lan']);

  await waitFor(() => readPid() === hub.child.pid, 'the discovery file');

  const raw = readRecord()!;
  assert.equal(raw.viewerPort, port);
  assert.ok((raw.agentPort as number) > 0);

  const exited = waitExit(hub.child);
  hub.child.kill('SIGTERM');
  await exited;
});

test('two simultaneous serves: exactly one survives, the other exits non-zero', async () => {
  // Both start without waiting for either to publish: that is the race the
  // sequential "second refuses" test cannot exercise.
  const first = startServe(['--port', String(await freePort())]);
  const second = startServe(['--port', String(await freePort())]);

  const loser = await waitForAnyExit(first.child, second.child);
  const winner = loser === first.child ? second : first;

  assert.notEqual(loser.exitCode, 0, 'the loser must exit non-zero');
  assert.match(
    (loser === first.child ? first : second).stderr(),
    /already running|--take-over/i,
  );
  assert.equal(winner.child.exitCode, null, 'exactly one serve must survive');

  await waitFor(() => readPid() === winner.child.pid, 'the winning hub');

  // The lock is the exclusion primitive; it must exist and name the winner.
  assert.equal(readFileSync(lockFile(), 'utf8'), String(winner.child.pid));

  const winnerExit = waitExit(winner.child);
  winner.child.kill('SIGTERM');
  await winnerExit;

  assert.equal(existsSync(lockFile()), false, 'the lock is released on close');
});

test('a stale discovery file naming a dead pid is reclaimed, not refused', async () => {
  const stale = await deadPid();
  mkdirSync(join(runtimeDir, 'pi-handset'), { recursive: true, mode: 0o700 });
  writeFileSync(
    discoveryFile(),
    JSON.stringify({
      agentPort: 54321,
      viewerPort: 8787,
      pid: stale,
      startedAt: new Date().toISOString(),
      protocolVersion: PROTOCOL_VERSION,
    }),
    { mode: 0o600 },
  );

  const port = await freePort();
  const hub = startServe(['--port', String(port)]);
  await waitFor(() => readPid() === hub.child.pid, 'the replacement hub');

  const raw = readRecord()!;
  assert.equal(raw.pid, hub.child.pid);
  assert.equal(raw.viewerPort, port);
  assert.ok((raw.agentPort as number) > 0);
  assert.equal(raw.protocolVersion, PROTOCOL_VERSION);

  const exited = waitExit(hub.child);
  hub.child.kill('SIGTERM');
  await exited;
});

test('a second serve refuses while the first is alive and leaves its file untouched', async () => {
  const first = startServe(['--port', String(await freePort())]);
  await waitFor(() => readPid() === first.child.pid, 'the first hub');
  const before = statSync(discoveryFile()).ino;

  const second = startServe(['--port', String(await freePort())]);
  const { code } = await waitExit(second.child);

  assert.equal(code, 1, 'a held lock is exit 1');
  assert.match(second.stderr(), /already running|--take-over/i);
  assert.equal(readPid(), first.child.pid, "the first hub's file is untouched");
  assert.equal(statSync(discoveryFile()).ino, before);
});

test('--take-over replaces a live hub and the loser cannot delete the winner file', async () => {
  const first = startServe(['--port', String(await freePort())]);
  await waitFor(() => readPid() === first.child.pid, 'the first hub');

  const second = startServe([
    '--take-over',
    '--port',
    String(await freePort()),
  ]);
  await waitFor(() => readPid() === second.child.pid, 'the takeover hub');

  const firstExit = waitExit(first.child);
  first.child.kill('SIGTERM');
  await firstExit;

  assert.equal(readPid(), second.child.pid, 'the taken-over hub must survive the loser');

  const secondExit = waitExit(second.child);
  second.child.kill('SIGTERM');
  await secondExit;

  assert.equal(existsSync(discoveryFile()), false, 'the winner removes its own file');
});

test('a hub whose close rejects yields a non-zero exit, not an unhandled rejection', async () => {
  const code = await finishShutdown(
    {
      close: async () => {
        throw new Error('listener teardown failed');
      },
    },
    runtimeDir,
    process.pid,
  );

  assert.equal(code, 1);
});

test('a mid-startup hub-close rejection still releases the lock and reports the tabled code', async () => {
  assert.equal(acquireLock(runtimeDir, process.pid).ok, true);
  assert.equal(existsSync(lockFile()), true, 'precondition: the lock is held');

  const code = await abortStartup(
    {
      close: async () => {
        throw new Error('hub close failed');
      },
    },
    runtimeDir,
    process.pid,
    'could not start the control socket: boom',
    1,
  );

  assert.equal(code, 1, 'the tabled startup code must survive a close rejection');
  assert.equal(existsSync(lockFile()), false, 'the lock must be released');
});

test('serve exits 2 on an unknown flag', async () => {
  const { code, stderr } = await runServeToExit(['--wat']);
  assert.equal(code, 2);
  assert.match(stderr, /--wat/);
});

test('serve exits 2 when the runtime dir is not a directory', async () => {
  const file = join(runtimeDir, 'not-a-dir');
  writeFileSync(file, 'x');
  const { code } = await runServeToExit([], { PI_HANDSET_RUNTIME_DIR: file });
  assert.equal(code, 2);
});

test('serve exits 1 and releases the lock when a live discovery record exists', async () => {
  mkdirSync(join(runtimeDir, 'pi-handset'), { recursive: true, mode: 0o700 });
  writeFileSync(
    discoveryFile(),
    JSON.stringify({
      agentPort: 12345,
      viewerPort: 8787,
      pid: process.pid,
      startedAt: new Date().toISOString(),
      protocolVersion: PROTOCOL_VERSION,
    }),
    { mode: 0o600 },
  );

  const { code } = await runServeToExit([]);
  assert.equal(code, 1);
  assert.equal(existsSync(lockFile()), false, 'the lock must be released');
});

test('serve exits 2 and releases the lock when the token cannot be loaded', async () => {
  const config = join(runtimeDir, 'config');
  mkdirSync(join(config, 'pi-handset'), { recursive: true });
  // Replace the would-be config dir with a file so `ensureConfigDir` throws.
  rmSync(join(config, 'pi-handset'), { recursive: true, force: true });
  writeFileSync(join(config, 'pi-handset'), 'not a dir');

  const { code } = await runServeToExit([], { XDG_CONFIG_HOME: config });
  assert.equal(code, 2);
  assert.equal(existsSync(lockFile()), false, 'the lock must be released');
});

test('serve exits 1 and releases the lock when the viewer port is taken', async () => {
  const blocker = createServer();
  await new Promise<void>((resolve) => blocker.listen(0, '0.0.0.0', () => resolve()));
  const port = (blocker.address() as AddressInfo).port;
  try {
    const { code } = await runServeToExit(['--port', String(port)]);
    assert.equal(code, 1);
    assert.equal(existsSync(lockFile()), false, 'the lock must be released');
  } finally {
    await new Promise<void>((resolve) => blocker.close(() => resolve()));
  }
});

test('serve exits 1 and releases the lock when the control socket cannot start', async () => {
  mkdirSync(join(runtimeDir, 'pi-handset', 'control.sock'), { recursive: true, mode: 0o700 });
  const { code } = await runServeToExit(['--port', String(await freePort())]);
  assert.equal(code, 1);
  assert.equal(existsSync(lockFile()), false, 'the lock must be released');
});

test('serve exits 2, releases the lock, and closes the control socket on a discovery failure', async () => {
  mkdirSync(join(runtimeDir, 'pi-handset', 'supervisor.json'), {
    recursive: true,
    mode: 0o700,
  });
  const { code } = await runServeToExit(['--port', String(await freePort())]);
  assert.equal(code, 2);
  assert.equal(existsSync(lockFile()), false, 'the lock must be released');
  assert.equal(
    existsSync(join(runtimeDir, 'pi-handset', 'control.sock')),
    false,
    'the control socket must be removed',
  );
});

test('serve exits 0 on SIGTERM and removes the control socket', async () => {
  const port = await freePort();
  const serve = startServe(['--port', String(port)]);
  await waitFor(() => readPid() === serve.child.pid, 'the discovery file');
  const socket = join(runtimeDir, 'pi-handset', 'control.sock');
  assert.equal(existsSync(socket), true, 'the control socket exists once serving');

  const exited = waitExit(serve.child);
  serve.child.kill('SIGTERM');
  const { code } = await exited;
  assert.equal(code, 0);
  assert.equal(existsSync(socket), false, 'the control socket is removed on SIGTERM');
});

test('a SIGTERM during startup still tears down, leaving no lock or socket', async () => {
  const port = await freePort();
  const serve = startServe(['--port', String(port)]);
  // The lock is written first; the hub, the control socket and the discovery
  // record all come after it. A stop requested the moment it appears therefore
  // lands inside startup, before there is anything to serve.
  await waitFor(() => existsSync(lockFile()), 'the lock file');
  const socket = join(runtimeDir, 'pi-handset', 'control.sock');

  const exited = waitExit(serve.child);
  serve.child.kill('SIGTERM');
  const { code } = await exited;

  assert.equal(code, 0, 'a stop during startup is a clean exit, not a signal death');
  assert.equal(existsSync(socket), false, 'no control socket is left behind');
  assert.equal(existsSync(lockFile()), false, 'the lock is released');
});

test('serve exits 0 on SIGINT and removes the control socket', async () => {
  const port = await freePort();
  const serve = await startReadyServe(port);
  const socket = join(runtimeDir, 'pi-handset', 'control.sock');
  assert.equal(existsSync(socket), true, 'the control socket exists once serving');

  const exited = waitExit(serve.child);
  serve.child.kill('SIGINT');
  const { code } = await exited;
  assert.equal(code, 0);
  assert.equal(existsSync(socket), false, 'the control socket is removed on SIGINT');
});

test('end to end: main.ts serve then main.ts pair prints a code the hub redeems', async () => {
  const port = await freePort();
  // Through the dispatcher: `startServe` defaults to `serve.ts` directly, so
  // only this entry exercises `main.ts`'s `case 'serve'`.
  const serve = startServe(['serve', '--port', String(port)], {}, mainEntry);
  await waitFor(() => readPid() === serve.child.pid, 'the discovery file');

  const pair = await runPairProcess();
  assert.equal(pair.code, 0, pair.stderr);
  const codes = printedCodes(pair.stdout);
  assert.equal(codes.length, 1, `expected one printed code in: ${pair.stdout}`);
  assert.match(pair.stdout, /pihandset:\/\/pair\?v=1&code=/);

  const paired = await redeem(port, codes[0]);
  assert.equal(paired.token, persistedToken(), 'the printed code must redeem');

  const exited = waitExit(serve.child);
  serve.child.kill('SIGTERM');
  await exited;
});

test('a pair mint invalidates an earlier SIGUSR1 code', async () => {
  const port = await freePort();
  const serve = await startReadyServe(port);
  serve.child.kill('SIGUSR1');
  await waitFor(() => printedCodes(serve.stdout()).length === 1, 'the SIGUSR1 code');
  const sigusr1Code = printedCodes(serve.stdout())[0];

  const pair = await runPairProcess();
  const pairCode = printedCodes(pair.stdout)[0];
  assert.notEqual(pairCode, sigusr1Code);

  assert.equal(await acceptsTicket(port, sigusr1Code), false, 'the older code is dead');
  assert.equal(await acceptsTicket(port, pairCode), true, 'the pair code is live');

  const exited = waitExit(serve.child);
  serve.child.kill('SIGTERM');
  await exited;
});

test('a SIGUSR1 mint invalidates an earlier pair code', async () => {
  const port = await freePort();
  const serve = await startReadyServe(port);
  const pair = await runPairProcess();
  const pairCode = printedCodes(pair.stdout)[0];

  serve.child.kill('SIGUSR1');
  await waitFor(() => printedCodes(serve.stdout()).length === 1, 'the SIGUSR1 code');
  const sigusr1Code = printedCodes(serve.stdout())[0];

  assert.equal(await acceptsTicket(port, pairCode), false, 'the older pair code is dead');
  assert.equal(await acceptsTicket(port, sigusr1Code), true, 'the SIGUSR1 code is live');

  const exited = waitExit(serve.child);
  serve.child.kill('SIGTERM');
  await exited;
});

test('serve spawns bare pi on start-session and SIGTERM kills the group', async () => {
  const port = await freePort();
  const shimDir = mkdtempSync(join(tmpdir(), 'pi-handset-serve-shim-'));
  scratchShimDirs.push(shimDir);
  const marker = join(shimDir, 'args.txt');
  const pidMarker = join(shimDir, 'pid.txt');
  writeFileSync(
    join(shimDir, 'pi'),
    '#!/bin/sh\n' +
      'echo "$$" > "$PI_HANDSET_SHIM_PID"\n' +
      'echo "$@" > "$PI_HANDSET_SHIM_ARGS"\n' +
      'pwd >> "$PI_HANDSET_SHIM_ARGS"\n' +
      'sleep 30\n',
    { mode: 0o755 },
  );

  const serve = startServe(['--port', String(port)], {
    PATH: `${shimDir}:${process.env.PATH ?? ''}`,
    PI_HANDSET_SHIM_ARGS: marker,
    PI_HANDSET_SHIM_PID: pidMarker,
  });
  await waitFor(() => readPid() === serve.child.pid, 'the discovery file');

  const viewer = await authViewer(port);
  viewer.send(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'start-session',
      id: 'start-1',
    }),
  );

  const result = await awaitMessage(viewer, 'command-result');
  assert.equal(result.ok, true, `start was refused: ${String(result.error)}`);
  await waitFor(() => existsSync(marker) && existsSync(pidMarker), 'the shim to run');

  const recorded = readFileSync(marker, 'utf8').trimEnd().split('\n');
  assert.equal(
    recorded[0],
    '--mode rpc --no-session',
    'production must spawn bare pi --mode rpc --no-session',
  );
  assert.ok(
    recorded[1].startsWith(tmpdir()),
    `the child cwd must be under ${tmpdir()}, got ${recorded[1]}`,
  );

  const shimPid = Number(readFileSync(pidMarker, 'utf8').trim());
  assert.equal(alive(shimPid), true, 'the shim must be running before the stop');

  // SIGTERM the supervisor. Its own graceful stop must group-kill the child.
  // The 5s bound is strictly below DEFAULT_REGISTRATION_TIMEOUT_MS, so the
  // registration reaper cannot be what kills it.
  const exited = waitExit(serve.child);
  serve.child.kill('SIGTERM');
  await exited;
  await waitFor(() => !alive(shimPid), 'the shim to die with the supervisor', 5000);
});

test('--max-sessions caps the number of app-started sessions', async () => {
  const port = await freePort();
  const shimDir = mkdtempSync(join(tmpdir(), 'pi-handset-serve-cap-shim-'));
  scratchShimDirs.push(shimDir);
  writeFileSync(
    join(shimDir, 'pi'),
    '#!/bin/sh\n' + 'echo "$$" > "$0.pid"\n' + 'sleep 30\n',
    { mode: 0o755 },
  );

  const serve = startServe(['--port', String(port), '--max-sessions', '1'], {
    PATH: `${shimDir}:${process.env.PATH ?? ''}`,
  });
  await waitFor(() => readPid() === serve.child.pid, 'the discovery file');

  const viewer = await authViewer(port);

  viewer.send(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'start-session',
      id: 'start-1',
    }),
  );
  const first = await awaitMessage(viewer, 'command-result');
  assert.equal(first.id, 'start-1');
  assert.equal(first.ok, true, `start was refused: ${String(first.error)}`);

  viewer.send(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'start-session',
      id: 'start-2',
    }),
  );
  const second = await awaitMessage(viewer, 'command-result');
  assert.equal(second.id, 'start-2');
  assert.equal(second.ok, false);
  assert.equal(second.error, 'too many app sessions');

  const shimPidFile = `${join(shimDir, 'pi')}.pid`;
  await waitFor(() => existsSync(shimPidFile), 'the shim to start');
  const shimPid = Number(readFileSync(shimPidFile, 'utf8').trim());

  const exited = waitExit(serve.child);
  serve.child.kill('SIGTERM');
  await exited;
  await waitFor(() => !alive(shimPid), 'the shim to die with the supervisor', 5000);
});

// --- M2: the boot reaper over a real hard-killed hub ---

/** The children pidfile the supervisor writes beside its discovery record. */
function childrenFile(): string {
  return join(runtimeDir, 'pi-handset', 'children.json');
}

/** The live `/proc/<pid>/cmdline`, NUL-split with the padding removed. */
function readCmdline(pid: number): string[] {
  try {
    return readFileSync(`/proc/${pid}/cmdline`, 'utf8')
      .split('\0')
      .filter((part) => part.length > 0);
  } catch {
    return [];
  }
}

/** Writes the title-rewriting `pi` shim and its env; returns the env to pass. */
function rewriterShim(): { dir: string; env: Record<string, string> } {
  const dir = mkdtempSync(join(tmpdir(), 'pi-handset-serve-rewriter-'));
  scratchShimDirs.push(dir);
  writeTitleRewriter(dir);
  return {
    dir,
    env: {
      PATH: `${dir}:${process.env.PATH ?? ''}`,
      [TITLE_REWRITER_PID_ENV]: join(dir, 'rewriter.pid'),
      [TITLE_REWRITER_ARGV_ENV]: join(dir, 'rewriter.argv'),
    },
  };
}

/** Starts a session through the hub and waits until the shim is running. */
async function startRewriterSession(port: number, shimDir: string): Promise<number> {
  const viewer = await authViewer(port);
  viewer.send(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      type: 'start-session',
      id: 'start-rewriter',
    }),
  );
  const result = await awaitMessage(viewer, 'command-result');
  assert.equal(result.ok, true, `start was refused: ${String(result.error)}`);
  const pidFile = join(shimDir, 'rewriter.pid');
  await waitFor(() => existsSync(pidFile), 'the title-rewriter shim to run');
  return Number(readFileSync(pidFile, 'utf8').trim());
}

test('a SIGKILLed hub leaves its title-rewriting child, and the next boot reaps it', async () => {
  const port = await freePort();
  const shim = rewriterShim();
  const env = shim.env;

  const first = startServe(['--port', String(port)], env);
  await waitFor(() => readPid() === first.child.pid, 'the first discovery file');

  const shimPid = await startRewriterSession(port, shim.dir);
  assert.equal(alive(shimPid), true, 'the shim must be running');

  // The proof this witness can see the fault the old one could not: the live
  // argv is the title, not the pre-exec original.
  await waitFor(() => readCmdline(shimPid)[0] === 'pi', 'the child to rewrite its argv');
  const original = JSON.parse(readFileSync(join(shim.dir, 'rewriter.argv'), 'utf8')) as string[];
  assert.notDeepEqual(readCmdline(shimPid), original);

  await waitFor(() => existsSync(childrenFile()), 'the children record');

  // A hard kill runs no cleanup at all.
  const firstExit = waitExit(first.child);
  first.child.kill('SIGKILL');
  await firstExit;
  assert.equal(alive(shimPid), true, 'the orphan must survive the hard kill');
  assert.equal(existsSync(childrenFile()), true, 'its record must survive too');

  // The next boot reaps it, even though it rewrote its own argv.
  const second = startServe(['--port', String(await freePort())], env);
  await waitFor(() => readPid() === second.child.pid, 'the second hub');
  await waitFor(() => !alive(shimPid), 'the next boot to reap the orphan');
  await waitFor(() => !existsSync(childrenFile()), 'the consumed record to be removed');

  const secondExit = waitExit(second.child);
  second.child.kill('SIGTERM');
  await secondExit;
});

test('a --take-over boot does not reap the previous hub\'s child', async () => {
  const port = await freePort();
  const shim = rewriterShim();
  const env = shim.env;

  const first = startServe(['--port', String(port)], env);
  await waitFor(() => readPid() === first.child.pid, 'the first hub');
  const shimPid = await startRewriterSession(port, shim.dir);

  const second = startServe(['--take-over', '--port', String(await freePort())], env);
  await waitFor(() => readPid() === second.child.pid, 'the takeover hub');

  assert.equal(
    alive(shimPid),
    true,
    '--take-over must not signal a still-live hub child',
  );

  const secondExit = waitExit(second.child);
  second.child.kill('SIGTERM');
  await secondExit;
  const firstExit = waitExit(first.child);
  first.child.kill('SIGTERM');
  await firstExit;
  await waitFor(() => !alive(shimPid), 'the shim to die with its own hub', 5000);
});
