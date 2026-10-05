// The process supervisor: spawns and owns headless pi children.
//
// Every test here crosses a real process boundary — a real `sh` child, a real
// process group, a real temp directory. Nothing is mocked: the point of the
// spawner is exactly the behaviour mocks cannot show.

import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, test } from 'node:test';

import { createSpawner, defaultProjectArgs } from '../../src/hub/spawner.ts';
import type { ChildExitEvent, Spawner } from '../../src/hub/spawner.ts';

const spawners: Spawner[] = [];
const scratchDirs: string[] = [];

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'pi-droid-spawner-test-'));
  scratchDirs.push(dir);
  return dir;
}

afterEach(async () => {
  // Never leak a child or a temp dir, even on a failed test.
  while (spawners.length > 0) await spawners.pop()!.close();
  for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true });
  scratchDirs.length = 0;
});

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(
  predicate: () => boolean,
  what: string,
  timeoutMs = 5000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await delay(20);
  }
  throw new Error(`timed out waiting for ${what}`);
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

/**
 * Subscribes to the spawner's child-exit notifications and reads them one at a
 * time. A notification that arrives before anyone awaits is buffered, so no
 * test depends on timing.
 */
function exitCollector(spawner: Spawner): {
  events: ChildExitEvent[];
  unsubscribe: () => void;
  next: (timeoutMs?: number) => Promise<ChildExitEvent>;
} {
  const events: ChildExitEvent[] = [];
  let waiter: ((event: ChildExitEvent) => void) | null = null;
  const unsubscribe = spawner.onChildExit((event) => {
    if (waiter !== null) {
      const resolve = waiter;
      waiter = null;
      resolve(event);
      return;
    }
    events.push(event);
  });
  return {
    events,
    unsubscribe,
    next(timeoutMs = 5000): Promise<ChildExitEvent> {
      const queued = events.shift();
      if (queued !== undefined) return Promise.resolve(queued);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          waiter = null;
          reject(new Error('timed out waiting for a child-exit notification'));
        }, timeoutMs);
        waiter = (event) => {
          clearTimeout(timer);
          resolve(event);
        };
      });
    },
  };
}

test('a spawned child runs in a fresh empty directory under tempRoot, and owns(pid) is true', async () => {
  const tempRoot = scratch();
  const markerDir = scratch();
  const marker = join(markerDir, 'pwd.txt');
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'pwd > "$1"; sleep 30', 'sh', marker],
    tempRoot,
  });
  spawners.push(spawner);

  assert.deepEqual(readdirSync(tempRoot), [], 'tempRoot starts empty');

  const pid = await spawner.spawn();
  await waitFor(() => readText(marker) !== null, 'the child to write its cwd');

  const cwd = readText(marker)!.trim();
  assert.ok(
    cwd.startsWith(tempRoot),
    `the child cwd must be under tempRoot, got ${cwd}`,
  );
  assert.deepEqual(
    readdirSync(cwd),
    [],
    'the child directory must be fresh and empty',
  );
  assert.equal(spawner.owns(pid), true);
  assert.equal(spawner.owns(1), false);
  assert.equal(spawner.owns('4242'), false);
});

test('spawn rejects once maxSessions children are live', async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot,
    maxSessions: 1,
  });
  spawners.push(spawner);

  await spawner.spawn();
  await assert.rejects(
    () => spawner.spawn(),
    /too many app sessions/,
    'the second spawn must be refused at the cap',
  );
});

test('kill signals the whole process group, not just the direct child', async () => {
  const tempRoot = scratch();
  const markerDir = scratch();
  const marker = join(markerDir, 'grandchild.txt');
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 300 & echo $! > "$1"; wait', 'sh', marker],
    tempRoot,
  });
  spawners.push(spawner);

  const pid = await spawner.spawn();
  await waitFor(() => readText(marker) !== null, 'the grandchild pid');
  const grandchild = Number(readText(marker)!.trim());
  assert.ok(alive(grandchild), 'the grandchild must be alive before the kill');

  spawner.kill(pid);

  await waitFor(
    () => !alive(pid) && !alive(grandchild),
    'both the direct child and the grandchild to die',
  );
});

test('kill escalates to SIGKILL for a SIGTERM-ignoring child', async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', "trap '' TERM; sleep 300"],
    tempRoot,
    terminateTimeoutMs: 200,
  });
  spawners.push(spawner);

  const pid = await spawner.spawn();
  assert.ok(alive(pid));

  spawner.kill(pid);

  await waitFor(() => !alive(pid), 'the SIGTERM-ignoring child to be SIGKILLed', 3000);
});

test('an unconfirmed child is reaped after the registration deadline', async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot,
    registrationTimeoutMs: 200,
  });
  spawners.push(spawner);

  const pid = await spawner.spawn();
  await waitFor(() => !alive(pid), 'the unconfirmed child to be reaped', 3000);
  await waitFor(
    () => readdirSync(tempRoot).length === 0,
    'the reaped child temp dir to be removed',
  );
});

test('confirm clears the registration deadline', async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot,
    registrationTimeoutMs: 200,
  });
  spawners.push(spawner);

  const pid = await spawner.spawn();
  spawner.confirm(pid);
  await delay(500);
  assert.equal(alive(pid), true, 'a confirmed child must outlive the deadline');
});

test('close kills every child and removes every temp dir, idempotently', async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot,
  });
  spawners.push(spawner);

  const first = await spawner.spawn();
  const second = await spawner.spawn();
  assert.equal(readdirSync(tempRoot).length, 2, 'two child dirs exist before close');

  await spawner.close();
  assert.equal(alive(first), false, 'the first child must be dead after close');
  assert.equal(alive(second), false, 'the second child must be dead after close');
  assert.deepEqual(readdirSync(tempRoot), [], 'every temp dir must be removed');

  // Idempotent: a second close is a no-op, not a throw.
  await spawner.close();
});

test('spawn rejects and leaks nothing when the command does not exist', async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'definitely-not-a-binary',
    tempRoot,
  });
  spawners.push(spawner);

  await assert.rejects(() => spawner.spawn());
  assert.deepEqual(
    readdirSync(tempRoot),
    [],
    'the error path must remove the temp dir it created',
  );
});

test('stdin is never closed while the child runs', async () => {
  const tempRoot = scratch();
  const markerDir = scratch();
  const marker = join(markerDir, 'eof.txt');
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'cat > /dev/null; echo eof > "$1"; sleep 30', 'sh', marker],
    tempRoot,
    // A long deadline so the reaper cannot be mistaken for a closed stdin.
    registrationTimeoutMs: 60_000,
  });
  spawners.push(spawner);

  const pid = await spawner.spawn();
  // Give `cat` ample time to observe EOF, if stdin were closed.
  await delay(500);
  assert.equal(
    readText(marker),
    null,
    'stdin must stay open: cat must not see EOF and write the marker',
  );
  assert.equal(alive(pid), true, 'the child must still be running');

  await spawner.close();
  assert.equal(alive(pid), false, 'close must kill the child');
});

test('spawn rejects, rather than throwing synchronously, when the temp dir cannot be created', async () => {
  // A missing tempRoot makes mkdtempSync throw (ENOENT). That setup failure
  // must surface as a rejected promise: the hub's start-session handler only
  // guards the async path, so a synchronous throw would kill the process.
  const missingRoot = join(scratch(), 'does-not-exist');
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot: missingRoot,
  });
  spawners.push(spawner);

  let pending: Promise<number> | undefined;
  assert.doesNotThrow(() => {
    pending = spawner.spawn();
  }, 'spawn must not throw synchronously');
  await assert.rejects(pending!, /ENOENT/);
});

test('close also kills a spawn that is still in flight', async () => {
  // spawn() returns before the 'spawn' event fires. close() runs in that
  // window, so its snapshot of the child map is still empty; the spawn handler
  // must notice the closed flag and kill the child rather than registering it.
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot,
  });
  spawners.push(spawner);

  const pending = spawner.spawn();
  await spawner.close();

  await assert.rejects(pending, /spawner is closed/);
  assert.deepEqual(readdirSync(tempRoot), [], 'no temp dir may survive the close');
});

// --- project spawns: the caller's directory must survive every exit path ---

/** A project dir with a marker file, so a removal is unmistakable. */
function projectDir(): string {
  const dir = scratch();
  writeFileSync(join(dir, 'marker.txt'), 'keep me');
  return dir;
}

function assertProjectIntact(dir: string): void {
  assert.equal(existsSync(dir), true, `the project dir ${dir} must survive`);
  assert.equal(existsSync(join(dir, 'marker.txt')), true, 'its contents must survive');
}

test('defaultProjectArgs picks exactly one approve flag', () => {
  assert.deepEqual(defaultProjectArgs(true), ['--mode', 'rpc', '--approve']);
  assert.deepEqual(defaultProjectArgs(false), ['--mode', 'rpc', '--no-approve']);
});

test('a project spawn runs in the caller directory and survives kill and close', async () => {
  const dir = projectDir();
  const spawner = createSpawner({
    command: 'sh',
    projectArgs: () => ['-c', 'sleep 30'],
  });
  spawners.push(spawner);

  const pid = await spawner.spawn({ cwd: dir });
  assert.equal(spawner.owns(pid), true, 'a project spawn is still owned');
  assertProjectIntact(dir);

  spawner.kill(pid);
  await waitFor(() => !alive(pid), 'the killed project child to die');
  assertProjectIntact(dir);

  await spawner.spawn({ cwd: dir });
  await spawner.close();
  assertProjectIntact(dir);
});

test('the registration reaper leaves a project dir alone', async () => {
  const dir = projectDir();
  const spawner = createSpawner({
    command: 'sh',
    projectArgs: () => ['-c', 'sleep 30'],
    registrationTimeoutMs: 50,
  });
  spawners.push(spawner);

  const pid = await spawner.spawn({ cwd: dir });
  await waitFor(() => !alive(pid), 'the unconfirmed project child to be reaped', 3000);
  await waitFor(() => !spawner.owns(pid), 'the reaper to forget the child');
  assertProjectIntact(dir);
});

test('close immediately after a project spawn leaves the project dir alone', async () => {
  const dir = projectDir();
  const spawner = createSpawner({
    command: 'sh',
    projectArgs: () => ['-c', 'sleep 30'],
  });
  spawners.push(spawner);

  const pending = spawner.spawn({ cwd: dir });
  await spawner.close();

  await assert.rejects(pending, /spawner is closed/);
  assertProjectIntact(dir);
});

test('a failed command leaves a project dir alone', async () => {
  const dir = projectDir();
  const spawner = createSpawner({ command: 'pi-droid-no-such-binary' });
  spawners.push(spawner);

  await assert.rejects(() => spawner.spawn({ cwd: dir }));
  assertProjectIntact(dir);
});

test('a self-exiting project child leaves the project dir alone', async () => {
  const dir = projectDir();
  const spawner = createSpawner({
    command: 'sh',
    projectArgs: () => ['-c', 'exit 0'],
  });
  spawners.push(spawner);

  const pid = await spawner.spawn({ cwd: dir });
  await waitFor(() => !spawner.owns(pid), 'the self-exiting child to be reaped', 3000);
  assertProjectIntact(dir);
});

test('a synchronous spawn throw leaves a project dir alone', async () => {
  const dir = projectDir();
  // A NUL byte in an argument makes child_process.spawn throw synchronously,
  // exercising the sync-catch removal guard.
  const spawner = createSpawner({
    command: 'sh',
    projectArgs: () => ['\0'],
  });
  spawners.push(spawner);

  await assert.rejects(() => spawner.spawn({ cwd: dir }));
  assertProjectIntact(dir);
});

// --- child-exit notifications: the lifecycle surface the hub builds on ---

test('onChildExit reports a child that exits on its own', async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'exit 0'],
    tempRoot,
    // Long enough that the deadline cannot be mistaken for the child's exit.
    registrationTimeoutMs: 60_000,
  });
  spawners.push(spawner);
  const exits = exitCollector(spawner);

  const pid = await spawner.spawn();
  const event = await exits.next();

  assert.deepEqual(event, { pid, reason: 'exit' });
});

test('onChildExit reports the registration deadline', async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot,
    registrationTimeoutMs: 200,
  });
  spawners.push(spawner);
  const exits = exitCollector(spawner);

  const pid = await spawner.spawn();

  assert.deepEqual(await exits.next(3000), { pid, reason: 'deadline' });
});

test("onChildExit still reports an already-confirmed child's later exit", async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot,
    registrationTimeoutMs: 60_000,
  });
  spawners.push(spawner);
  const exits = exitCollector(spawner);

  const pid = await spawner.spawn();
  spawner.confirm(pid);
  spawner.kill(pid);

  assert.deepEqual(await exits.next(3000), { pid, reason: 'exit' });
});

test('a deadline reap reports exactly once', async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot,
    registrationTimeoutMs: 200,
  });
  spawners.push(spawner);
  const exits = exitCollector(spawner);

  const pid = await spawner.spawn();
  assert.deepEqual(await exits.next(3000), { pid, reason: 'deadline' });

  // The SIGKILLed child's own `exit` arrives later; because the deadline reap
  // already removed the entry, it must not re-report.
  await delay(300);
  assert.deepEqual(exits.events, []);
});

test('unsubscribing stops notifications', async () => {
  const tempRoot = scratch();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot,
    registrationTimeoutMs: 60_000,
  });
  spawners.push(spawner);
  const exits = exitCollector(spawner);
  exits.unsubscribe();

  const pid = await spawner.spawn();
  spawner.kill(pid);
  await waitFor(() => !alive(pid), 'the killed child to die');
  await delay(100);

  assert.deepEqual(exits.events, []);
});
