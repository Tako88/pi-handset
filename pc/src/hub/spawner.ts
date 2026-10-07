/**
 * The process supervisor for app-started headless pi sessions.
 *
 * The hub spawns one `pi --mode rpc --no-session` child per app-started
 * session, each in a fresh empty temp directory. A *project* spawn (`cwd` is
 * supplied) instead runs in the caller's existing directory with
 * `defaultProjectArgs`; the spawner never removes that directory. The child is
 * its own process group (`detached: true`), so a kill signals the whole group —
 * a running `bash` tool command is a grandchild, and signalling only the direct
 * child would leave it alive.
 *
 * stdin is opened but never written and never ended: rpc reads commands from
 * it, and an accidental `.end()` would close the session's command channel.
 * stdout/stderr get no-op `data` listeners so a chatty child cannot fill its
 * pipes and block.
 *
 * Every child is reaped on exit, on a spawn error, on the registration
 * deadline (a child that never registers is dead weight), on `kill`, and on
 * `close`. `close()` is idempotent.
 */

import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';

import { isProcessAlive } from './discovery.ts';

/** How many app-started sessions may run at once. */
export const DEFAULT_MAX_SESSIONS = 8;

/**
 * How long a spawned child may take to register before it is reaped.
 *
 * Measured cold-start register latency on the dev host (Step 22 capstone, a
 * real bare `pi --mode rpc --no-session` with configured-extension discovery):
 * ~210 ms. The value is the `60_000` floor, far above 3x the worst observed, so
 * a slow real-pi cold start is never killed by the reaper.
 * `SpawnerOptions.registrationTimeoutMs` overrides it in tests.
 */
export const DEFAULT_REGISTRATION_TIMEOUT_MS = 60_000;

export interface SpawnerOptions {
  /** The pi binary. Defaults to `'pi'`, resolved through `PATH`. */
  command?: string;
  /** Production args. Defaults to `['--mode','rpc','--no-session']`. */
  args?: readonly string[];
  /**
   * Args for a project spawn (one with a caller-supplied `cwd`). Defaults to
   * `defaultProjectArgs`. */
  projectArgs?: (trust: boolean) => readonly string[];
  /** The child environment. Defaults to `process.env`. */
  env?: NodeJS.ProcessEnv;
  /** Where per-session temp directories are created. Defaults to `os.tmpdir()`. */
  tempRoot?: string;
  /** Simultaneous children cap. Defaults to `DEFAULT_MAX_SESSIONS`. */
  maxSessions?: number;
  /** Registration deadline in ms. Defaults to `DEFAULT_REGISTRATION_TIMEOUT_MS`. */
  registrationTimeoutMs?: number;
  /** SIGTERM → SIGKILL grace period in ms. Defaults to 5000. */
  terminateTimeoutMs?: number;
  /**
   * The pidfile recording spawned children for the boot reaper. When omitted,
   * no record is written. See `reapOrphans`.
   */
  pidFile?: string;
  /** Optional diagnostic sink. */
  debug?: (text: string) => void;
}

/** Per-spawn options. A `cwd` selects a project spawn. */
export interface SpawnOptions {
  /** Run the child in this existing directory instead of a fresh temp dir. */
  cwd?: string;
  /** Whether the project is trusted for this run (project spawns only). */
  trust?: boolean;
}

export type ChildExitReason = 'exit' | 'error' | 'deadline';

/** One child-exit notification: the pid that left and why. */
export interface ChildExitEvent {
  readonly pid: number;
  readonly reason: ChildExitReason;
}

export interface Spawner {
  /** Spawns one child, resolving its process-group pid. Rejects over cap/ENOENT. */
  spawn(options?: SpawnOptions): Promise<number>;
  /** True while `pid` is a live child this spawner owns. */
  owns(pid: unknown): boolean;
  /** Clears the registration deadline once the child's `register` arrives. */
  confirm(pid: number): void;
  /** SIGTERMs the process group, escalating to SIGKILL after a bounded wait. */
  kill(pid: number): void;
  /**
   * Registers a listener fired once per child the spawner reaps, with the
   * reason. Returns an unsubscribe function. A listener that throws is
   * contained and reported to `debug`; it never breaks the reap.
   */
  onChildExit(listener: (event: ChildExitEvent) => void): () => void;
  /** Kills every child, removes every temp dir, clears every timer. Idempotent. */
  close(): Promise<void>;
}

interface Entry {
  readonly dir: string;
  readonly child: ChildProcess;
  /** True when this spawner created the dir and may remove it. */
  readonly owned: boolean;
  timer: NodeJS.Timeout | null;
  /**
   * The child's `/proc/<pid>/stat` start time (fork-stable), or null when the
   * stat read failed. Never an exec-dependent value: a real pi re-execs through
   * `env` and rewrites its argv, so any such value would be wrong at reap.
   */
  startTime: number | null;
}

/**
 * The args for a project spawn: exactly one of `--approve` / `--no-approve`
 * (pi's `--help`), plus rpc mode. No `--no-session`, so the child can
 * persist a resumable session in the project.
 */
export function defaultProjectArgs(trust: boolean): readonly string[] {
  return trust ? ['--mode', 'rpc', '--approve'] : ['--mode', 'rpc', '--no-approve'];
}

/** Signals the whole process group; a dead group is not an error. */
function signalGroup(pid: number, signal: NodeJS.Signals, debug?: (text: string) => void): void {
  try {
    process.kill(-pid, signal);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ESRCH') {
      debug?.(`could not signal group -${pid}: ${String(error)}`);
    }
  }
}

/**
 * A rejection reason that is always an `Error`. A `catch` binding is `unknown`,
 * and both `mkdtempSync` and `spawn` can throw anything; rejecting with a bare
 * value loses the stack, while the message a caller reports is unchanged (the
 * hub stringifies a non-Error the same way).
 */
function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

/**
 * Hands one stderr chunk to the diagnostic sink, one line per call. A spawned
 * pi's stderr is otherwise discarded, which makes the bridge's own diagnostics
 * — the socket close code above all — unreachable for a session the hub
 * started. Stdout is deliberately absent: a spawned pi prints its entire rpc
 * event stream there as JSON, which nobody reads and which would put the whole
 * transcript in the hub's log.
 */
function forwardChildLines(
  debug: ((text: string) => void) | undefined,
  chunk: Buffer,
): void {
  if (debug === undefined) return;
  for (const line of chunk.toString().split('\n')) {
    if (line.trim() !== '') debug(`stderr: ${line}\n`);
  }
}

export function createSpawner(options: SpawnerOptions = {}): Spawner {
  const command = options.command ?? 'pi';
  const args = options.args ?? ['--mode', 'rpc', '--no-session'];
  const projectArgs = options.projectArgs;
  const env = options.env ?? process.env;
  const tempRoot = options.tempRoot ?? tmpdir();
  const maxSessions = options.maxSessions ?? DEFAULT_MAX_SESSIONS;
  const registrationTimeoutMs =
    options.registrationTimeoutMs ?? DEFAULT_REGISTRATION_TIMEOUT_MS;
  const terminateTimeoutMs = options.terminateTimeoutMs ?? 5_000;
  const debug = options.debug;
  const pidFile = options.pidFile;
  const bootId = pidFile === undefined ? null : readBootId();

  const children = new Map<number, Entry>();
  const exitListeners = new Set<(event: ChildExitEvent) => void>();
  let closed = false;

  /**
   * Rewrites the pidfile from the live child map. Only fork-stable identity is
   * recorded: pid, the owned dir (null for a project spawn) and the start time.
   * Never throws (see `writeChildren`), so it cannot disturb a reap.
   */
  function persistChildren(): void {
    if (pidFile === undefined) return;
    const records: ChildRecord[] = [];
    for (const [childPid, entry] of children) {
      records.push({
        pid: childPid,
        dir: entry.owned ? entry.dir : null,
        startTime: entry.startTime,
      });
    }
    writeChildren(pidFile, tempRoot, bootId, records);
  }

  function removeDir(dir: string): void {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch (error) {
      debug?.(`could not remove ${dir}: ${String(error)}`);
    }
  }

  /**
   * Forgets a child, clears its deadline and removes its dir if it owns it.
   * Returns true when it actually removed an entry: the exit notification is
   * gated on that, so a deadline reap followed by the child's own `exit` (or a
   * `terminate` followed by its `exit`) reports exactly once.
   */
  function reap(pid: number): boolean {
    const entry = children.get(pid);
    if (entry === undefined) return false;
    children.delete(pid);
    if (entry.timer !== null) clearTimeout(entry.timer);
    if (entry.owned) removeDir(entry.dir);
    persistChildren();
    return true;
  }

  /** Fires every child-exit listener; a throwing listener is contained. */
  function notifyExit(pid: number, reason: ChildExitReason): void {
    for (const listener of [...exitListeners]) {
      try {
        listener({ pid, reason });
      } catch (error) {
        debug?.(`child-exit listener failed: ${String(error)}`);
      }
    }
  }

  function armRegistration(pid: number): void {
    const timer = setTimeout(() => {
      signalGroup(pid, 'SIGKILL', debug);
      if (reap(pid)) notifyExit(pid, 'deadline');
    }, registrationTimeoutMs);
    timer.unref();
    const entry = children.get(pid);
    if (entry !== undefined) entry.timer = timer;
  }

  function spawnChild(options?: SpawnOptions): Promise<number> {
    if (closed) return Promise.reject(new Error('spawner is closed'));
    if (children.size >= maxSessions) {
      return Promise.reject(new Error('too many app sessions'));
    }
    // A caller-supplied cwd is a project spawn: we must never remove it.
    const owned = options?.cwd === undefined;
    let dir: string;
    if (owned) {
      try {
        dir = mkdtempSync(join(tempRoot, 'pi-handset-session-'));
      } catch (error) {
        return Promise.reject(toError(error));
      }
    } else {
      dir = options.cwd as string;
    }
    const spawnArgs = owned
      ? args
      : (projectArgs ?? defaultProjectArgs)(options?.trust ?? false);
    let child: ChildProcess;
    try {
      child = spawn(command, spawnArgs, {
        cwd: dir,
        env,
        detached: true,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    } catch (error) {
      if (owned) removeDir(dir);
      return Promise.reject(toError(error));
    }
    // Drain both pipes; never touch stdin (rpc reads commands from it). The
    // drain is the point — an unread pipe blocks a chatty child in write(2) —
    // so only the sink decides whether the read stderr lines go anywhere.
    child.stdout?.on('data', () => {});
    child.stderr?.on('data', (chunk: Buffer) => forwardChildLines(debug, chunk));
    return new Promise<number>((resolve, reject) => {
      let pid: number | null = null;
      child.once('spawn', () => {
        const spawnedPid = child.pid;
        if (spawnedPid === undefined) {
          if (owned) removeDir(dir);
          reject(new Error('spawned child has no pid'));
          return;
        }
        if (closed) {
          signalGroup(spawnedPid, 'SIGKILL', debug);
          if (owned) removeDir(dir);
          reject(new Error('spawner is closed'));
          return;
        }
        pid = spawnedPid;
        const stat = readProcStat(spawnedPid);
        children.set(pid, {
          dir,
          child,
          owned,
          timer: null,
          startTime: stat?.startTime ?? null,
        });
        persistChildren();
        if (stat === null) {
          // A transient /proc failure at spawn: one bounded retry refreshes the
          // record. Still null means the guard declines (the non-Linux case).
          setImmediate(() => {
            const entry = children.get(spawnedPid);
            if (entry === undefined) return;
            const refreshed = readProcStat(spawnedPid);
            if (refreshed === null) return;
            entry.startTime = refreshed.startTime;
            persistChildren();
          });
        }
        armRegistration(pid);
        resolve(pid);
      });
      child.once('error', (error) => {
        // A failed spawn emits `error` and not a guaranteed `exit`, so the
        // cleanup must live here too.
        if (pid === null) {
          if (owned) removeDir(dir);
          reject(error);
        } else if (reap(pid)) {
          notifyExit(pid, 'error');
        }
      });
      child.once('exit', () => {
        if (pid !== null) {
          if (reap(pid)) notifyExit(pid, 'exit');
        } else if (owned) {
          removeDir(dir);
        }
      });
    });
  }

  function confirm(pid: number): void {
    const entry = children.get(pid);
    if (entry === undefined) return;
    if (entry.timer !== null) {
      clearTimeout(entry.timer);
      entry.timer = null;
    }
  }

  function kill(pid: number): void {
    const entry = children.get(pid);
    if (entry === undefined) return;
    signalGroup(pid, 'SIGTERM', debug);
    const timer = setTimeout(() => {
      if (children.has(pid)) signalGroup(pid, 'SIGKILL', debug);
    }, terminateTimeoutMs);
    timer.unref();
  }

  async function terminate(pid: number): Promise<void> {
    const entry = children.get(pid);
    if (entry === undefined) return;
    const { child, dir } = entry;
    if (entry.timer !== null) {
      clearTimeout(entry.timer);
      entry.timer = null;
    }
    const exited = new Promise<void>((resolve) => {
      if (child.exitCode !== null || child.signalCode !== null) {
        resolve();
        return;
      }
      child.once('exit', () => resolve());
    });
    signalGroup(pid, 'SIGTERM', debug);
    const escalated = new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        signalGroup(pid, 'SIGKILL', debug);
        resolve();
      }, terminateTimeoutMs);
      timer.unref();
      void exited.then(() => {
        clearTimeout(timer);
        resolve();
      });
    });
    await Promise.race([exited, escalated]);
    children.delete(pid);
    if (entry.owned) removeDir(dir);
  }

  async function close(): Promise<void> {
    if (closed) return;
    closed = true;
    await Promise.all([...children.keys()].map((pid) => terminate(pid)));
    persistChildren();
  }

  return {
    spawn: spawnChild,
    owns: (pid) => typeof pid === 'number' && children.has(pid),
    confirm,
    kill,
    onChildExit: (listener) => {
      exitListeners.add(listener);
      return () => {
        exitListeners.delete(listener);
      };
    },
    close,
  };
}
// --- M2: pidfile + boot reaper ---

export interface ChildRecord {
  pid: number;
  dir: string | null;
  startTime: number | null;
}

export interface ChildrenFile {
  version: 1;
  tempRoot: string;
  bootId: string | null;
  children: ChildRecord[];
}

export interface ProcStat {
  state: string;
  startTime: number;
}

/** The per-boot identity, or null when neither source is readable. */
export function readBootId(): string | null {
  try {
    const id = readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
    if (id.length > 0) return id;
  } catch {
    // Fall through to `btime`.
  }
  try {
    const match = /^btime\s+(\d+)\s*$/m.exec(readFileSync('/proc/stat', 'utf8'));
    if (match !== null) return `btime:${match[1]}`;
  } catch {
    // Not Linux, or /proc is unavailable: no per-boot identity.
  }
  return null;
}

/**
 * Parses `/proc/<pid>/stat`. The last `)` is the anchor: `comm` (field 2) may
 * contain spaces and parentheses, but it is the only parenthesized field. The
 * token after the last `)` is field 3 (`state`); field 22 (`starttime`, in
 * clock ticks since boot) is token 19. Returns null on anything malformed.
 */
export function parseProcStat(raw: string): ProcStat | null {
  const close = raw.lastIndexOf(')');
  if (close === -1) return null;
  const tokens = raw.slice(close + 1).trim().split(/\s+/);
  if (tokens.length < 20) return null;
  const state = tokens[0];
  const startTime = Number(tokens[19]);
  if (!Number.isSafeInteger(startTime) || startTime < 0) return null;
  return { state, startTime };
}

/** Reads and parses `/proc/<pid>/stat`; null when it cannot be read/parsed. */
export function readProcStat(pid: number): ProcStat | null {
  try {
    return parseProcStat(readFileSync(`/proc/${pid}/stat`, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Atomically writes the children record: a fresh temp file at `0600`, then a
 * `rename` over the target, so a reader never sees a partial file. Never
 * throws — a failed write must not disturb a reap or startup.
 */
export function writeChildren(
  pidFile: string,
  tempRoot: string,
  bootId: string | null,
  records: readonly ChildRecord[],
): void {
  try {
    const file: ChildrenFile = { version: 1, tempRoot, bootId, children: [...records] };
    mkdirSync(dirname(pidFile), { recursive: true, mode: 0o700 });
    const temp = `${pidFile}.tmp.${randomBytes(6).toString('hex')}`;
    writeFileSync(temp, JSON.stringify(file), { mode: 0o600 });
    renameSync(temp, pidFile);
  } catch {
    // Best-effort: the record is a hint for the next boot, never authority.
  }
}

/**
 * True iff the record's fork-stable identity matches a live process's stat.
 *
 * `recordedBootId` is the file-level per-boot identity captured when the
 * record was written; `currentBootId` is this boot's. They must both exist and
 * agree — a record from another boot cannot name a live process of this one.
 * (`bootId` is deliberately file-level, not a child field: the child record
 * carries only `pid`/`dir`/`startTime`.) `startTime` is assigned at fork and
 * is unchanged by `execve` or `process.title`, so comparing a spawn-time record
 * to a reap-time read is sound.
 */
export function verifyChild(
  record: ChildRecord,
  recordedBootId: string | null,
  currentBootId: string | null,
  stat: ProcStat | null,
): boolean {
  return (
    record.startTime !== null &&
    recordedBootId !== null &&
    currentBootId !== null &&
    recordedBootId === currentBootId &&
    stat !== null &&
    stat.startTime === record.startTime
  );
}

/**
 * True iff `dir` is a temp dir this project owns: a `pi-handset-session-*`
 * basename directly under the recorded `tempRoot`. The recorded root — not the
 * boot-time `os.tmpdir()` — is what closes the TMPDIR-changed case.
 */
export function isOwnedTempDir(dir: string, tempRoot: string): boolean {
  return basename(dir).startsWith('pi-handset-session-') && dirname(dir) === tempRoot;
}

/** How long to wait for a SIGKILLed orphan to actually leave, per child. */
const REAP_KILL_WAIT_MS = 1_000;
/** Poll interval while waiting for a SIGKILLed orphan to die. */
const REAP_POLL_MS = 5;

/**
 * Blocks (bounded) until `pid` is gone. `Atomics.wait` is the stdlib's only
 * synchronous sleep and leaves the event loop otherwise unusable for the wait,
 * which is fine: the reaper runs once, before the hub accepts connections.
 */
function waitForDeath(pid: number, timeoutMs: number): void {
  const sleeper = new Int32Array(new SharedArrayBuffer(4));
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!isProcessAlive(pid)) return;
    // A SIGKILLed process becomes a zombie until its parent reaps it, and
    // `kill(pid, 0)` reports a zombie as alive. Blocking here would prevent
    // this process from reaping its own child, so a zombie is treated as gone.
    const stat = readProcStat(pid);
    if (stat === null || stat.state === 'Z') return;
    Atomics.wait(sleeper, 0, 0, REAP_POLL_MS);
  }
}

/** Unlinks `path` only when it is a regular file; never follows a symlink. */
function removeRegularFile(path: string): void {
  try {
    if (!lstatSync(path).isFile()) return;
    unlinkSync(path);
  } catch {
    // Already gone or unreadable: nothing to do.
  }
}

/** One child record, or null when it is malformed (such an entry is skipped). */
function parseChildRecord(value: unknown): ChildRecord | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const { pid, dir, startTime } = record;
  if (typeof pid !== 'number' || !Number.isSafeInteger(pid) || pid <= 0) return null;
  if (dir !== null && typeof dir !== 'string') return null;
  if (
    startTime !== null &&
    (typeof startTime !== 'number' || !Number.isSafeInteger(startTime) || startTime < 0)
  ) {
    return null;
  }
  return { pid, dir, startTime };
}

/** The parsed file, or null when it is not valid; a malformed entry is skipped. */
function parseChildren(raw: string): ChildrenFile | null {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  if (record.version !== 1) return null;
  if (typeof record.tempRoot !== 'string') return null;
  const bootId = record.bootId;
  if (bootId !== null && typeof bootId !== 'string') return null;
  if (!Array.isArray(record.children)) return null;
  const children: ChildRecord[] = [];
  for (const entry of record.children) {
    const parsed = parseChildRecord(entry);
    if (parsed !== null) children.push(parsed);
  }
  return { version: 1, tempRoot: record.tempRoot, bootId, children };
}

/**
 * Reads the children file. Only a regular file is read: a missing path, a
 * directory and a symlink all resolve to null and are left untouched. A
 * corrupt or wrong-version file is deleted (it can never be reaped) and
 * resolves to null. Never throws.
 */
function readChildrenFile(
  pidFile: string,
  debug?: (text: string) => void,
): ChildrenFile | null {
  let stats;
  try {
    stats = lstatSync(pidFile);
  } catch {
    return null;
  }
  if (!stats.isFile()) return null;

  let raw: string;
  try {
    raw = readFileSync(pidFile, 'utf8');
  } catch (error) {
    debug?.(`could not read ${pidFile}: ${String(error)}`);
    return null;
  }
  const parsed = parseChildren(raw);
  if (parsed === null) {
    debug?.(`ignoring a corrupt children file at ${pidFile}`);
    removeRegularFile(pidFile);
    return null;
  }
  return parsed;
}

/** Removes a recorded dir, but only when it is one this project owns. */
function removeOwnedDir(
  record: ChildRecord,
  tempRoot: string,
  debug?: (text: string) => void,
): void {
  if (record.dir === null || !isOwnedTempDir(record.dir, tempRoot)) return;
  try {
    rmSync(record.dir, { recursive: true, force: true });
  } catch (error) {
    debug?.(`could not remove ${record.dir}: ${String(error)}`);
  }
}

/**
 * Reaps one record. Returns true only when the process was verified and killed.
 * Dir removal is gated on the same verdict as the kill, plus a certainly-dead,
 * foreign-boot or zombie child.
 */
function reapOne(
  record: ChildRecord,
  file: ChildrenFile,
  currentBootId: string | null,
  debug?: (text: string) => void,
): boolean {
  // 1. A record from another boot cannot name a live process of this boot:
  //    decline to signal, but its dir is certainly orphaned.
  if (file.bootId !== null && currentBootId !== null && file.bootId !== currentBootId) {
    removeOwnedDir(record, file.tempRoot, debug);
    return false;
  }
  // 2. Not alive: the dir is certainly orphaned.
  if (!isProcessAlive(record.pid)) {
    removeOwnedDir(record, file.tempRoot, debug);
    return false;
  }
  const stat = readProcStat(record.pid);
  // 3. Unreadable stat: spare both. The safe direction is never to signal.
  if (stat === null) return false;
  // 4. A zombie is not a live orphan; a SIGKILL would be discarded anyway.
  if (stat.state === 'Z') {
    removeOwnedDir(record, file.tempRoot, debug);
    return false;
  }
  // 5. Unverified identity (reused pid, null record, or unknown boot): spare.
  if (!verifyChild(record, file.bootId, currentBootId, stat)) return false;
  // 6. Verified: kill the group, wait bounded, then remove the owned dir.
  signalGroup(record.pid, 'SIGKILL', debug);
  waitForDeath(record.pid, REAP_KILL_WAIT_MS);
  removeOwnedDir(record, file.tempRoot, debug);
  return true;
}

/**
 * Reaps the still-live children a previous, hard-killed hub spawned, from the
 * pidfile it left at `pidFile`, and removes their owned temp dirs. Returns the
 * number of processes killed.
 *
 * Never throws and never aborts startup: a missing file is a no-op, a corrupt
 * or wrong-version file is deleted, a directory or symlink path is neither
 * followed nor unlinked, and a malformed entry is skipped. Only fork-stable
 * identity is trusted (see `verifyChild`); an unverifiable record is spared.
 */
export function reapOrphans(pidFile: string, debug?: (text: string) => void): number {
  const file = readChildrenFile(pidFile, debug);
  if (file === null) return 0;
  const currentBootId = readBootId();
  let killed = 0;
  for (const record of file.children) {
    try {
      if (reapOne(record, file, currentBootId, debug)) killed++;
    } catch (error) {
      debug?.(`skipping an unreadable child record: ${String(error)}`);
    }
  }
  // The record is consumed: whatever was spared will re-register with the new
  // hub as an ordinary PC session, and a stale file must not be re-reaped.
  removeRegularFile(pidFile);
  return killed;
}

