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
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

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
}

/**
 * The args for a project spawn: exactly one of `--approve` / `--no-approve`
 * (pi 0.87.1 `--help`), plus rpc mode. No `--no-session`, so the child can
 * persist a resumable session in the project.
 */
export function defaultProjectArgs(trust: boolean): readonly string[] {
  return trust ? ['--mode', 'rpc', '--approve'] : ['--mode', 'rpc', '--no-approve'];
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

  const children = new Map<number, Entry>();
  const exitListeners = new Set<(event: ChildExitEvent) => void>();
  let closed = false;

  function removeDir(dir: string): void {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch (error) {
      debug?.(`could not remove ${dir}: ${String(error)}`);
    }
  }

  /** Signals the whole process group; a dead group is not an error. */
  function signalGroup(pid: number, signal: NodeJS.Signals): void {
    try {
      process.kill(-pid, signal);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ESRCH') {
        debug?.(`could not signal group -${pid}: ${String(error)}`);
      }
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
      signalGroup(pid, 'SIGKILL');
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
        dir = mkdtempSync(join(tempRoot, 'pi-droid-session-'));
      } catch (error) {
        return Promise.reject(error);
      }
    } else {
      dir = options!.cwd as string;
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
      return Promise.reject(error);
    }
    // Drain both pipes; never touch stdin (rpc reads commands from it).
    child.stdout?.on('data', () => {});
    child.stderr?.on('data', () => {});
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
          signalGroup(spawnedPid, 'SIGKILL');
          if (owned) removeDir(dir);
          reject(new Error('spawner is closed'));
          return;
        }
        pid = spawnedPid;
        children.set(pid, { dir, child, owned, timer: null });
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
    signalGroup(pid, 'SIGTERM');
    const timer = setTimeout(() => {
      if (children.has(pid)) signalGroup(pid, 'SIGKILL');
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
    signalGroup(pid, 'SIGTERM');
    const escalated = new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        signalGroup(pid, 'SIGKILL');
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
