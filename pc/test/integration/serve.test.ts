import assert from 'node:assert/strict';
import { afterEach, beforeEach, test } from 'node:test';
import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

const pcRoot = fileURLToPath(new URL('../..', import.meta.url));
const serveEntry = fileURLToPath(new URL('../../src/cli/serve.ts', import.meta.url));

let runtimeDir: string;
let spawned: ChildProcess[];

beforeEach(() => {
  runtimeDir = mkdtempSync(join(tmpdir(), 'pi-droid-serve-'));
  spawned = [];
});

afterEach(() => {
  // Never leave orphans: kill anything still running, even on a failed test.
  for (const child of spawned) {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGKILL');
    }
  }
  rmSync(runtimeDir, { recursive: true, force: true });
});

interface ServeHandle {
  child: ChildProcess;
  stderr: () => string;
}

function startServe(args: string[] = []): ServeHandle {
  const child = spawn(process.execPath, [serveEntry, ...args], {
    cwd: pcRoot,
    env: { ...process.env, PI_DROID_RUNTIME_DIR: runtimeDir },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  spawned.push(child);
  let stderr = '';
  child.stderr!.on('data', (chunk) => {
    stderr += String(chunk);
  });
  return { child, stderr: () => stderr };
}

function discoveryFile(): string {
  return join(runtimeDir, 'pi-droid', 'supervisor.json');
}

function lockFile(): string {
  return join(runtimeDir, 'pi-droid', 'supervisor.lock');
}

function readPid(): number | null {
  try {
    return JSON.parse(readFileSync(discoveryFile(), 'utf8')).pid;
  } catch {
    return null;
  }
}

function waitExit(child: ChildProcess): Promise<{ code: number | null; signal: string | null }> {
  return new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve({ code: child.exitCode, signal: child.signalCode });
      return;
    }
    child.once('exit', (code, signal) => resolve({ code, signal }));
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

test('serve writes a 0600 discovery file and removes it on SIGTERM', async () => {
  const first = startServe();

  await waitFor(() => readPid() === first.child.pid, 'the discovery file');
  assert.equal(statSync(discoveryFile()).mode & 0o777, 0o600);
  assert.equal(statSync(join(runtimeDir, 'pi-droid')).mode & 0o777, 0o700);

  const raw = JSON.parse(readFileSync(discoveryFile(), 'utf8'));
  assert.equal(raw.pid, first.child.pid);
  assert.equal(raw.port, 8787);
  assert.equal(raw.protocolVersion, PROTOCOL_VERSION);
  assert.equal(typeof raw.startedAt, 'string');

  const exited = waitExit(first.child);
  first.child.kill('SIGTERM');
  await exited;

  assert.equal(existsSync(discoveryFile()), false, 'the file is removed on close');
});

test('two simultaneous serves: exactly one survives, the other exits non-zero', async () => {
  // Both start without waiting for either to publish: that is the race the
  // sequential "second refuses" test cannot exercise.
  const first = startServe();
  const second = startServe(['--port', '9123']);

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
  mkdirSync(join(runtimeDir, 'pi-droid'), { recursive: true, mode: 0o700 });
  writeFileSync(
    discoveryFile(),
    JSON.stringify({
      port: 8787,
      pid: stale,
      startedAt: new Date().toISOString(),
      protocolVersion: PROTOCOL_VERSION,
    }),
    { mode: 0o600 },
  );

  const hub = startServe(['--port', '9123']);
  await waitFor(() => readPid() === hub.child.pid, 'the replacement hub');

  const raw = JSON.parse(readFileSync(discoveryFile(), 'utf8'));
  assert.equal(raw.pid, hub.child.pid);
  assert.equal(raw.port, 9123);
  assert.equal(raw.protocolVersion, PROTOCOL_VERSION);

  const exited = waitExit(hub.child);
  hub.child.kill('SIGTERM');
  await exited;
});

test('a second serve refuses while the first is alive and leaves its file untouched', async () => {
  const first = startServe();
  await waitFor(() => readPid() === first.child.pid, 'the first hub');
  const before = statSync(discoveryFile()).ino;

  const second = startServe(['--port', '9123']);
  const { code } = await waitExit(second.child);

  assert.notEqual(code, 0, 'the second serve must exit non-zero');
  assert.match(second.stderr(), /already running|--take-over/i);
  assert.equal(readPid(), first.child.pid, "the first hub's file is untouched");
  assert.equal(statSync(discoveryFile()).ino, before);
});

test('--take-over replaces a live hub and the loser cannot delete the winner file', async () => {
  const first = startServe();
  await waitFor(() => readPid() === first.child.pid, 'the first hub');

  const second = startServe(['--take-over', '--port', '9123']);
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
