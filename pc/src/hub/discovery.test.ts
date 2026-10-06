import assert from 'node:assert/strict';
import { afterEach, beforeEach, test } from 'node:test';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Deliberately `.ts`, and deliberately written before `./discovery.ts` exists:
// the red run must fail with an unresolved import, not a loader error.
import {
  acquireLock,
  holdsLock,
  isProcessAlive,
  lockPath,
  readDiscovery,
  releaseLock,
  removeDiscovery,
  resolveRuntimeDir,
  supervisorPath,
  writeDiscovery,
} from './discovery.ts';
import { PROTOCOL_VERSION } from '../protocol/protocol.ts';

// Tests never touch the real `$XDG_RUNTIME_DIR`; they pass a throwaway temp dir.
let runtimeDir: string;

beforeEach(() => {
  runtimeDir = mkdtempSync(join(tmpdir(), 'pi-droid-runtime-'));
});

afterEach(() => {
  rmSync(runtimeDir, { recursive: true, force: true });
});

function record(overrides: Partial<Parameters<typeof writeDiscovery>[1]> = {}) {
  return {
    agentPort: 54321,
    viewerPort: 8787,
    pid: process.pid,
    startedAt: '2026-09-30T00:00:00.000Z',
    protocolVersion: PROTOCOL_VERSION,
    ...overrides,
  };
}

/** Seeds a raw supervisor.json, bypassing writeDiscovery's validation. */
function seedRaw(contents: string): void {
  mkdirSync(join(runtimeDir, 'pi-droid'), { recursive: true, mode: 0o700 });
  writeFileSync(supervisorPath(runtimeDir), contents, { mode: 0o600 });
}

test('supervisorPath points at <runtimeDir>/pi-droid/supervisor.json', () => {
  assert.equal(
    supervisorPath(runtimeDir),
    join(runtimeDir, 'pi-droid', 'supervisor.json'),
  );
});

test('resolveRuntimeDir prefers an absolute PI_DROID_RUNTIME_DIR', () => {
  assert.equal(
    resolveRuntimeDir({ PI_DROID_RUNTIME_DIR: '/custom/runtime' }, 1000, '/custom/tmp'),
    '/custom/runtime',
  );
});

test('resolveRuntimeDir uses XDG_RUNTIME_DIR when the override is absent', () => {
  assert.equal(
    resolveRuntimeDir({ XDG_RUNTIME_DIR: '/run/user/1000' }, 1000, '/custom/tmp'),
    '/run/user/1000',
  );
});

test('resolveRuntimeDir lets the override beat XDG_RUNTIME_DIR', () => {
  assert.equal(
    resolveRuntimeDir(
      { PI_DROID_RUNTIME_DIR: '/override', XDG_RUNTIME_DIR: '/run/user/1000' },
      1000,
      '/custom/tmp',
    ),
    '/override',
  );
});

test('resolveRuntimeDir falls back to <tmp>/pi-droid-<uid>', () => {
  assert.equal(resolveRuntimeDir({}, 1000, '/custom/tmp'), '/custom/tmp/pi-droid-1000');
});

test('resolveRuntimeDir ignores a relative override and falls back', () => {
  assert.equal(
    resolveRuntimeDir({ PI_DROID_RUNTIME_DIR: 'relative/path' }, 1000, '/custom/tmp'),
    '/custom/tmp/pi-droid-1000',
  );
});

test('writeDiscovery creates the pi-droid directory 0700 and the file 0600', () => {
  writeDiscovery(runtimeDir, record());

  assert.equal(statSync(join(runtimeDir, 'pi-droid')).mode & 0o777, 0o700);
  assert.equal(statSync(supervisorPath(runtimeDir)).mode & 0o777, 0o600);
});

test('writeDiscovery writes exactly agentPort, viewerPort, pid, startedAt and protocolVersion', () => {
  writeDiscovery(runtimeDir, record({ viewerPort: 9123 }));

  const parsed = JSON.parse(readFileSync(supervisorPath(runtimeDir), 'utf8')) as Record<string, unknown>;
  assert.deepEqual(Object.keys(parsed).sort(), [
    'agentPort',
    'pid',
    'protocolVersion',
    'startedAt',
    'viewerPort',
  ]);
  assert.equal('token' in parsed, false, 'the token must never appear in the runtime file');
});

test('writeDiscovery is atomic: rewriting replaces the inode, not the contents in place', () => {
  writeDiscovery(runtimeDir, record());
  const before = statSync(supervisorPath(runtimeDir)).ino;

  writeDiscovery(runtimeDir, record({ viewerPort: 9123 }));

  const after = statSync(supervisorPath(runtimeDir)).ino;
  assert.notEqual(after, before, 'temp file + rename changes the inode');
});

test('writeDiscovery leaves no temp files behind', () => {
  writeDiscovery(runtimeDir, record());
  writeDiscovery(runtimeDir, record({ viewerPort: 9123 }));

  assert.deepEqual(readdirSync(join(runtimeDir, 'pi-droid')), ['supervisor.json']);
});

test('readDiscovery returns the record for a live, matching file', () => {
  writeDiscovery(runtimeDir, record());

  const found = readDiscovery(runtimeDir);

  assert.deepEqual(found, record());
});

test('readDiscovery returns null when the file is absent', () => {
  assert.equal(readDiscovery(runtimeDir), null);
});

test('readDiscovery returns null for corrupt JSON', () => {
  seedRaw('{ this is not json');

  assert.equal(readDiscovery(runtimeDir, () => true), null);
});

test('readDiscovery returns null when the JSON is not an object', () => {
  seedRaw('42');

  assert.equal(readDiscovery(runtimeDir, () => true), null);
});

test('readDiscovery returns null for a malformed record', () => {
  seedRaw(
    JSON.stringify({
      agentPort: 54321,
      viewerPort: 'base',
      pid: 1,
      startedAt: 'x',
      protocolVersion: 1,
    }),
  );

  assert.equal(readDiscovery(runtimeDir, () => true), null);
});

test('readDiscovery returns null when the recorded pid is not alive', () => {
  writeDiscovery(runtimeDir, record({ pid: 4242 }));

  assert.equal(readDiscovery(runtimeDir, () => false), null);
});

test('readDiscovery returns null on a protocolVersion mismatch', () => {
  writeDiscovery(runtimeDir, record({ protocolVersion: PROTOCOL_VERSION + 1 }));

  assert.equal(readDiscovery(runtimeDir, () => true), null);
});

test('writeDiscovery records agentPort, viewerPort, pid and protocol version by value', () => {
  writeDiscovery(runtimeDir, record({ agentPort: 51234, viewerPort: 9123, pid: 4242 }));

  const parsed = JSON.parse(readFileSync(supervisorPath(runtimeDir), 'utf8')) as Record<string, unknown>;
  assert.equal(parsed.agentPort, 51234);
  assert.equal(parsed.viewerPort, 9123);
  assert.equal(parsed.pid, 4242);
  assert.equal(parsed.protocolVersion, PROTOCOL_VERSION);
  assert.equal(typeof parsed.startedAt, 'string');
});

test('readDiscovery rejects a startedAt that is not a parseable time', () => {
  seedRaw(
    JSON.stringify({
      agentPort: 54321,
      viewerPort: 8787,
      pid: process.pid,
      startedAt: 'not-a-date',
      protocolVersion: PROTOCOL_VERSION,
    }),
  );

  assert.equal(readDiscovery(runtimeDir), null);
});

test('writeDiscovery refuses a symlinked pi-droid runtime directory', () => {
  const target = mkdtempSync(join(tmpdir(), 'pi-droid-outside-'));
  try {
    symlinkSync(target, join(runtimeDir, 'pi-droid'));
    assert.throws(() => writeDiscovery(runtimeDir, record()), /symlink/i);
  } finally {
    rmSync(target, { recursive: true, force: true });
  }
});

test('writeDiscovery refuses when the runtime path is not a directory', () => {
  writeFileSync(join(runtimeDir, 'pi-droid'), 'not a directory', { mode: 0o600 });

  assert.throws(() => writeDiscovery(runtimeDir, record()), /not a directory/i);
});

test('acquireLock refuses a symlinked pi-droid runtime directory', () => {
  const target = mkdtempSync(join(tmpdir(), 'pi-droid-outside-'));
  try {
    symlinkSync(target, join(runtimeDir, 'pi-droid'));
    assert.throws(() => acquireLock(runtimeDir, process.pid), /symlink/i);
  } finally {
    rmSync(target, { recursive: true, force: true });
  }
});

test('readDiscovery liveness check defaults to the real process check', () => {
  writeDiscovery(runtimeDir, record({ pid: process.pid }));

  assert.notEqual(readDiscovery(runtimeDir), null);
});

test('isProcessAlive reports a running process as alive', () => {
  assert.equal(isProcessAlive(process.pid), true);
});

test('isProcessAlive reports a reaped pid as dead', async () => {
  const { spawn } = await import('node:child_process');
  const child = spawn(process.execPath, ['-e', 'process.exit(0)']);
  const pid = child.pid!;
  await new Promise<void>((resolve) => child.once('exit', () => resolve()));

  assert.equal(isProcessAlive(pid), false);
});

test('isProcessAlive treats EPERM as alive (exists, not ours)', () => {
  const eperm = () => {
    const error: NodeJS.ErrnoException = new Error('EPERM');
    error.code = 'EPERM';
    throw error;
  };
  assert.equal(isProcessAlive(4242, eperm), true);
});

test('isProcessAlive treats ESRCH as dead', () => {
  const esrch = () => {
    const error: NodeJS.ErrnoException = new Error('ESRCH');
    error.code = 'ESRCH';
    throw error;
  };
  assert.equal(isProcessAlive(4242, esrch), false);
});

test('removeDiscovery removes the file', () => {
  writeDiscovery(runtimeDir, record({ pid: 4242 }));

  removeDiscovery(runtimeDir, 4242);

  assert.equal(readDiscovery(runtimeDir, () => true), null);
});

test('removeDiscovery is idempotent when the file is already gone', () => {
  assert.doesNotThrow(() => removeDiscovery(runtimeDir, 4242));
});

test('removeDiscovery with a mismatched pid leaves a successor hub file intact', () => {
  writeDiscovery(runtimeDir, record({ pid: 9999 }));

  removeDiscovery(runtimeDir, 4242);

  const raw = JSON.parse(readFileSync(supervisorPath(runtimeDir), 'utf8')) as Record<string, unknown>;
  assert.equal(raw.pid, 9999, 'a taken-over hub must not delete the new file');
});

/** A pid that is guaranteed to be dead: spawn and reap a short-lived child. */
async function deadPid(): Promise<number> {
  const { spawn } = await import('node:child_process');
  const child = spawn(process.execPath, ['-e', 'process.exit(0)']);
  const pid = child.pid!;
  await new Promise<void>((resolve) => child.once('exit', () => resolve()));
  return pid;
}

test('lockPath points at <runtimeDir>/pi-droid/supervisor.lock', () => {
  assert.equal(lockPath(runtimeDir), join(runtimeDir, 'pi-droid', 'supervisor.lock'));
});

test('acquireLock creates a 0600 lock naming the pid', () => {
  const result = acquireLock(runtimeDir, process.pid);

  assert.deepEqual(result, { ok: true });
  assert.equal(statSync(lockPath(runtimeDir)).mode & 0o777, 0o600);
  assert.equal(readFileSync(lockPath(runtimeDir), 'utf8'), String(process.pid));
  assert.equal(holdsLock(runtimeDir, process.pid), true);
});

test('acquireLock refuses while a live holder owns the lock', () => {
  acquireLock(runtimeDir, process.pid);

  const result = acquireLock(runtimeDir, process.pid + 1);

  assert.equal(result.ok, false);
  assert.equal(result.ok === false ? result.holderPid : null, process.pid);
});

test('acquireLock reclaims a stale lock whose holder is dead', async () => {
  const stale = await deadPid();
  mkdirSync(join(runtimeDir, 'pi-droid'), { recursive: true, mode: 0o700 });
  writeFileSync(lockPath(runtimeDir), String(stale), { mode: 0o600 });

  const result = acquireLock(runtimeDir, process.pid);

  assert.deepEqual(result, { ok: true });
  assert.equal(readFileSync(lockPath(runtimeDir), 'utf8'), String(process.pid));
});

test('acquireLock with force steals a live holder lock', () => {
  acquireLock(runtimeDir, process.pid);

  const result = acquireLock(runtimeDir, process.pid + 1, true);

  assert.deepEqual(result, { ok: true });
  assert.equal(readFileSync(lockPath(runtimeDir), 'utf8'), String(process.pid + 1));
});

test('releaseLock unlinks only the lock naming our pid', () => {
  acquireLock(runtimeDir, process.pid);

  releaseLock(runtimeDir, process.pid + 1);
  assert.equal(holdsLock(runtimeDir, process.pid), true, 'a foreign pid must not release');

  releaseLock(runtimeDir, process.pid);
  assert.equal(existsSync(lockPath(runtimeDir)), false);
});
