// The process supervisor: spawns and owns headless pi children.
//
// Every test here crosses a real process boundary — a real `sh` child, a real
// process group, a real temp directory. Nothing is mocked: the point of the
// spawner is exactly the behaviour mocks cannot show.

import assert from 'node:assert/strict';
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { afterEach, test } from 'node:test';

import {
  createSpawner,
  defaultProjectArgs,
  parseProcStat,
  readBootId,
  readProcStat,
  reapOrphans,
  verifyChild,
  writeChildren,
} from '../../src/hub/spawner.ts';
import type { ChildExitEvent, ChildRecord, Spawner } from '../../src/hub/spawner.ts';
import {
  TITLE_REWRITER_ARGV_ENV,
  TITLE_REWRITER_PID_ENV,
  writeTitleRewriter,
} from './title_rewriter.ts';

const spawners: Spawner[] = [];
const scratchDirs: string[] = [];

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'pi-handset-spawner-test-'));
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
  const spawner = createSpawner({ command: 'pi-handset-no-such-binary' });
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

// --- M2: the pidfile record and the pid-reuse guard ---
//
// The record holds fork-stable identity only: pid, dir, startTime. There is no
// cmdline and no exe, because a spawn-time read of either races the
// `env -> node` re-exec and `process.title` rewrite a real pi performs: the
// recorded value could never match the reap-time value, so the guard would
// silently spare every real orphan.

/** The shape the spawner writes to the pidfile. */
interface ChildrenFileShape {
  version: number;
  tempRoot: string;
  bootId: string | null;
  children: ChildRecord[];
}

/** The parsed children file at `path`, or null when it is missing/corrupt. */
function readChildrenFile(path: string): ChildrenFileShape | null {
  const raw = readText(path);
  if (raw === null) return null;
  try {
    return JSON.parse(raw) as ChildrenFileShape;
  } catch {
    return null;
  }
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

/** A fresh pidfile path inside a new scratch dir removed by afterEach. */
function pidFilePath(): string {
  return join(scratch(), 'children.json');
}

/** Spawns one child and reads back the record the spawner wrote for it. */
async function spawnWithRecord(
  spawner: Spawner,
  pidFile: string,
  options?: { cwd?: string },
): Promise<{ pid: number; record: ChildRecord }> {
  const pid = await spawner.spawn(options);
  await waitFor(
    () => readChildrenFile(pidFile)?.children.length === 1,
    'the pidfile record',
  );
  return { pid, record: readChildrenFile(pidFile)!.children[0] };
}

/** Writes a tampered children file in a fresh scratch dir; returns its path. */
function tamperChildren(
  tempRoot: string,
  bootId: string | null,
  records: readonly ChildRecord[],
): string {
  const path = pidFilePath();
  writeChildren(path, tempRoot, bootId, records);
  return path;
}

test('the spawner records a spawned child in the pidfile and removes it on exit', async () => {
  const tempRoot = scratch();
  const pidFile = pidFilePath();
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'sleep 30'],
    tempRoot,
    pidFile,
  });
  spawners.push(spawner);

  const pid = await spawner.spawn();
  await waitFor(
    () => readChildrenFile(pidFile)?.children.length === 1,
    'the spawner to record the child',
  );

  const file = readChildrenFile(pidFile)!;
  assert.equal(file.version, 1);
  assert.equal(file.tempRoot, tempRoot);
  assert.equal(file.bootId, readBootId());

  const record = file.children[0];
  assert.deepEqual(
    Object.keys(record).sort(),
    ['dir', 'pid', 'startTime'],
    'the record must carry fork-stable identity only — no cmdline, no exe',
  );
  assert.equal(record.pid, pid);
  assert.ok(record.dir !== null && record.dir.startsWith(tempRoot), 'the dir is under tempRoot');
  assert.ok(basename(record.dir).startsWith('pi-handset-session-'));
  assert.ok(
    Number.isSafeInteger(record.startTime) && record.startTime! > 0,
    `startTime must be a finite positive integer, got ${String(record.startTime)}`,
  );

  spawner.kill(pid);
  await waitFor(
    () => readChildrenFile(pidFile)?.children.length === 0,
    'the record to be removed when the child exits',
  );
});

test('a project spawn is recorded with a null dir and its directory is never removed', async () => {
  const dir = projectDir();
  const tempRoot = scratch();
  const pidFile = pidFilePath();
  const spawner = createSpawner({
    command: 'sh',
    projectArgs: () => ['-c', 'sleep 30'],
    tempRoot,
    pidFile,
  });
  spawners.push(spawner);

  const { pid, record } = await spawnWithRecord(spawner, pidFile, { cwd: dir });
  assert.equal(record.dir, null, 'a project spawn never records a removable dir');
  assert.deepEqual(Object.keys(record).sort(), ['dir', 'pid', 'startTime']);

  const reaped = reapOrphans(tamperChildren(tempRoot, readBootId(), [record]));
  assert.equal(reaped, 1, 'the recorded project child is still reaped');
  await waitFor(() => !alive(pid), 'the project child to be reaped');
  assertProjectIntact(dir);
});

test("readProcStat reads a real child's start time and it is stable", async () => {
  const tempRoot = scratch();
  const pidFile = pidFilePath();
  const spawner = createSpawner({ command: 'sh', args: ['-c', 'sleep 30'], tempRoot, pidFile });
  spawners.push(spawner);

  const { pid, record } = await spawnWithRecord(spawner, pidFile);
  const first = readProcStat(pid);
  assert.ok(first !== null, 'a live child must have a readable stat');
  assert.ok(
    Number.isSafeInteger(first.startTime) && first.startTime > 0,
    `a real start time is a finite positive integer, got ${String(first.startTime)}`,
  );
  const second = readProcStat(pid);
  assert.ok(second !== null, 'a live child must still have a readable stat');
  // `state` is deliberately left out: a live process flips between R and S
  // between two reads, and nothing reads the field. The test below pins its
  // shape; `startTime` is what the pid-reuse guard compares.
  assert.equal(second.startTime, first.startTime, 'two reads of a live process must agree');
  assert.equal(first.startTime, record.startTime, 'the spawner recorded the same start time');
});

test("readProcStat reports a real child's state and start time", async () => {
  const tempRoot = scratch();
  const pidFile = pidFilePath();
  const spawner = createSpawner({ command: 'sh', args: ['-c', 'sleep 30'], tempRoot, pidFile });
  spawners.push(spawner);

  const { pid, record } = await spawnWithRecord(spawner, pidFile);
  const stat = readProcStat(pid);
  assert.ok(stat !== null);
  assert.match(stat.state, /^[RSDTtI]$/, `unexpected state ${stat.state}`);
  assert.equal(stat.startTime, record.startTime);
});

test('a subject that rewrites its own argv is still verified and reaped', async () => {
  const tempRoot = scratch();
  const scratchDir = scratch();
  const pidFile = join(scratchDir, 'children.json');
  const rewriterPid = join(scratchDir, 'rewriter.pid');
  const rewriterArgv = join(scratchDir, 'rewriter.argv');
  const script = writeTitleRewriter(scratchDir);
  const spawner = createSpawner({
    command: script,
    tempRoot,
    pidFile,
    env: {
      ...process.env,
      [TITLE_REWRITER_PID_ENV]: rewriterPid,
      [TITLE_REWRITER_ARGV_ENV]: rewriterArgv,
    },
  });
  spawners.push(spawner);

  const pid = await spawner.spawn();
  await waitFor(() => readText(rewriterPid) !== null, 'the subject pid file');
  assert.equal(Number(readText(rewriterPid)!.trim()), pid);

  // Proof the subject went through `env -> node` and rewrote its argv: the
  // live cmdline becomes the title, not the original `process.argv`.
  await waitFor(() => readCmdline(pid)[0] === 'pi', 'the subject to rewrite its argv');
  const original = JSON.parse(readText(rewriterArgv)!) as string[];
  assert.notDeepEqual(
    readCmdline(pid),
    original,
    'the live argv must differ from the pre-title original',
  );

  const file = readChildrenFile(pidFile)!;
  assert.equal(
    verifyChild(file.children[0], file.bootId, readBootId(), readProcStat(pid)),
    true,
    'the fork-stable record must verify against a subject that mutated its argv',
  );

  assert.equal(reapOrphans(pidFile), 1, 'the guard must reach the reaper');
  await waitFor(() => !alive(pid), 'the reaped subject to die');
  assert.equal(existsSync(file.children[0].dir!), false, 'its owned dir must be removed');
});

test('an unrelated live process is not killed when its start time differs', async () => {
  const tempRoot = scratch();
  const pidFile = pidFilePath();
  const spawner = createSpawner({ command: 'sh', args: ['-c', 'sleep 30'], tempRoot, pidFile });
  spawners.push(spawner);

  const { pid, record } = await spawnWithRecord(spawner, pidFile);
  const tampered: ChildRecord = { ...record, startTime: (record.startTime ?? 0) + 1 };
  assert.equal(reapOrphans(tamperChildren(tempRoot, readBootId(), [tampered])), 0);
  assert.equal(alive(pid), true, 'a process whose start time differs must be spared');
  assert.equal(existsSync(record.dir!), true, 'its dir must be spared too');
});

test('a record from a different boot is declined for signalling but its owned dir is removed', async () => {
  const tempRoot = scratch();
  const pidFile = pidFilePath();
  const spawner = createSpawner({ command: 'sh', args: ['-c', 'sleep 30'], tempRoot, pidFile });
  spawners.push(spawner);

  const { pid, record } = await spawnWithRecord(spawner, pidFile);
  const path = tamperChildren(tempRoot, 'a-different-boot', [record]);
  assert.equal(reapOrphans(path), 0, 'a foreign-boot record is not a kill');
  assert.equal(alive(pid), true, 'the process cannot be ours on this boot');
  assert.equal(existsSync(record.dir!), false, 'the certainly-orphaned dir is removed');
});

test('a record with a null start time is declined', async () => {
  const tempRoot = scratch();
  const pidFile = pidFilePath();
  const spawner = createSpawner({ command: 'sh', args: ['-c', 'sleep 30'], tempRoot, pidFile });
  spawners.push(spawner);

  const { pid, record } = await spawnWithRecord(spawner, pidFile);
  const tampered: ChildRecord = { ...record, startTime: null };
  assert.equal(reapOrphans(tamperChildren(tempRoot, readBootId(), [tampered])), 0);
  assert.equal(alive(pid), true, 'a null identity must never be signalled');
  assert.equal(existsSync(record.dir!), true, 'its dir must be spared');
});

test('a recorded dir whose basename is not pi-handset-session- is not removed', async () => {
  const tempRoot = scratch();
  const pidFile = pidFilePath();
  const spawner = createSpawner({ command: 'sh', args: ['-c', 'sleep 30'], tempRoot, pidFile });
  spawners.push(spawner);

  const { pid, record } = await spawnWithRecord(spawner, pidFile);
  const wrongDir = join(tempRoot, 'not-a-session-dir');
  mkdirSync(wrongDir);
  const tampered: ChildRecord = { ...record, dir: wrongDir };
  assert.equal(reapOrphans(tamperChildren(tempRoot, readBootId(), [tampered])), 1);
  await waitFor(() => !alive(pid), 'the verified process to die');
  assert.equal(existsSync(wrongDir), true, 'a non-session dir must never be removed');
});

test('a recorded dir whose parent is not the recorded tempRoot is not removed', async () => {
  const tempRoot = scratch();
  const pidFile = pidFilePath();
  const spawner = createSpawner({ command: 'sh', args: ['-c', 'sleep 30'], tempRoot, pidFile });
  spawners.push(spawner);

  const { pid, record } = await spawnWithRecord(spawner, pidFile);
  const otherParent = scratch();
  const wrongDir = join(otherParent, 'pi-handset-session-xyz');
  mkdirSync(wrongDir);
  const tampered: ChildRecord = { ...record, dir: wrongDir };
  assert.equal(reapOrphans(tamperChildren(tempRoot, readBootId(), [tampered])), 1);
  await waitFor(() => !alive(pid), 'the verified process to die');
  assert.equal(existsSync(wrongDir), true, 'a dir outside the recorded root must survive');
});

test('a pidfile path that is a directory is not followed or unlinked', () => {
  const path = join(scratch(), 'children.json');
  mkdirSync(path);
  assert.equal(reapOrphans(path), 0);
  assert.equal(lstatSync(path).isDirectory(), true, 'the directory must survive');
});

test('a pidfile path that is a symlink is not followed or unlinked', () => {
  const dir = scratch();
  const target = join(dir, 'real.json');
  writeChildren(target, tmpdir(), readBootId(), []);
  const link = join(dir, 'children.json');
  symlinkSync(target, link);

  assert.equal(reapOrphans(link), 0);
  assert.equal(lstatSync(link).isSymbolicLink(), true, 'the link must survive');
  assert.equal(lstatSync(target).isFile(), true, 'the target must not be removed');
});

test('a recorded tempRoot that differs from the current os.tmpdir() still reaps its dir', async () => {
  const tempRoot = scratch();
  assert.notEqual(tempRoot, tmpdir(), 'precondition: the recorded root is not os.tmpdir()');
  const pidFile = pidFilePath();
  const spawner = createSpawner({ command: 'sh', args: ['-c', 'sleep 30'], tempRoot, pidFile });
  spawners.push(spawner);

  const { pid, record } = await spawnWithRecord(spawner, pidFile);
  // A dir the spawner does not own, so only the reaper can remove it — otherwise
  // the spawner's own exit cleanup would mask the reaper's tempRoot check.
  const ownedDir = mkdtempSync(join(tempRoot, 'pi-handset-session-'));
  const tampered: ChildRecord = { ...record, dir: ownedDir };
  assert.equal(reapOrphans(tamperChildren(tempRoot, readBootId(), [tampered])), 1);
  await waitFor(() => !alive(pid), 'the verified process to die');
  assert.equal(existsSync(ownedDir), false, 'the dir under the recorded root is removed');
});

test('parseProcStat treats a Z state as not alive', () => {
  const zombie = parseProcStat('4242 (pi) Z 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19');
  assert.ok(zombie !== null);
  assert.equal(zombie.state, 'Z');
  assert.equal(zombie.startTime, 19);

  const real = parseProcStat(readFileSync('/proc/self/stat', 'utf8'));
  assert.ok(real !== null);
  assert.match(real.state, /^[RSDTtI]$/);
  assert.ok(Number.isSafeInteger(real.startTime) && real.startTime > 0);
});

test('a corrupt pidfile is deleted and the reaper never throws', () => {
  const path = join(scratch(), 'children.json');
  writeFileSync(path, '{ definitely not json');
  let reaped = -1;
  assert.doesNotThrow(() => {
    reaped = reapOrphans(path);
  }, 'a corrupt record must not escape the reaper');
  assert.equal(reaped, 0);
  assert.equal(existsSync(path), false, 'a corrupt record is deleted');
});

test('a wrong-version pidfile is deleted and the reaper never throws', () => {
  const path = join(scratch(), 'children.json');
  writeFileSync(
    path,
    JSON.stringify({ version: 99, tempRoot: tmpdir(), bootId: null, children: [] }),
  );
  assert.equal(reapOrphans(path), 0);
  assert.equal(existsSync(path), false, 'a record this code cannot read is deleted');
});

test('a malformed entry is skipped, not fatal', () => {
  const path = join(scratch(), 'children.json');
  writeFileSync(
    path,
    JSON.stringify({
      version: 1,
      tempRoot: tmpdir(),
      bootId: null,
      children: [{ pid: 'nope' }],
    }),
  );
  assert.equal(reapOrphans(path), 0, 'a malformed entry must not abort the sweep');
  assert.equal(existsSync(path), false);
});
