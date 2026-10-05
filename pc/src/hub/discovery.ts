/**
 * The supervisor discovery file.
 *
 * A supervisor writes `<runtimeDir>/pi-droid/supervisor.json` where
 * `<runtimeDir>` is an absolute `$PI_DROID_RUNTIME_DIR` (a test-only override),
 * else an absolute `$XDG_RUNTIME_DIR`, else `<tmpdir>/pi-droid-<uid>`. The
 * override exists because `$XDG_RUNTIME_DIR` is unset for many users and tests
 * must never touch the real one.
 *
 * The payload is `{ agentPort, viewerPort, pid, startedAt, protocolVersion }`
 * and deliberately **not** the token. Both ports are published because the
 * record is what an *agent* reads to find the hub, and the agent listener is
 * the ephemeral one; the viewer port is included for tooling and diagnostics.
 * The token has exactly one home
 * (`<configDir>/pi-droid/token`, via `auth.ts`); duplicating it here would
 * create a second copy to leak and a second copy to desynchronize on rotation.
 *
 * A reader treats a corrupt/unparseable file, a dead pid, and a protocol
 * version mismatch all as "no hub" — the file is a hint, never authority. The
 * write is temp-file + `rename`, so a reader never observes a partial file.
 *
 * This module also owns the exclusion lock at
 * `<runtimeDir>/pi-droid/supervisor.lock` (`0600`). Its exclusive create
 * (`open(..., 'wx')`) is what makes two simultaneous supervisor starts
 * exclusive; the lock is held for the process lifetime and the discovery file
 * is only the published record. See `acquireLock`.
 *
 * The directory is `0700` and the file `0600`. Startup-fatal problems throw
 * (as in `auth.ts`), because this is called once at startup, not per message.
 */

import { randomBytes } from 'node:crypto';
import {
  chmodSync,
  closeSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { isAbsolute, join } from 'node:path';
import type { Stats } from 'node:fs';

import { PROTOCOL_VERSION } from '../protocol/protocol.ts';

const DISCOVERY_DIR_MODE = 0o700;
const DISCOVERY_FILE_MODE = 0o600;
const LOCK_FILE_MODE = 0o600;

/** What a running supervisor publishes. Never contains the token. */
export interface DiscoveryRecord {
  /** The ephemeral loopback port the agent-side (bridge) listener bound. */
  agentPort: number;
  /** The configured viewer-side (app) port. */
  viewerPort: number;
  pid: number;
  startedAt: string;
  protocolVersion: number;
}

function currentUid(): number {
  return typeof process.getuid === 'function' ? process.getuid() : 0;
}

/** Resolves the runtime dir: absolute override, then absolute XDG, then tmp. */
export function resolveRuntimeDir(
  env: NodeJS.ProcessEnv = process.env,
  uid: number = currentUid(),
  tmp: string = tmpdir(),
): string {
  const override = env.PI_DROID_RUNTIME_DIR;
  if (typeof override === 'string' && override.length > 0 && isAbsolute(override)) {
    return override;
  }
  const xdg = env.XDG_RUNTIME_DIR;
  if (typeof xdg === 'string' && xdg.length > 0 && isAbsolute(xdg)) {
    return xdg;
  }
  return join(tmp, `pi-droid-${uid}`);
}

/** The discovery file path under a runtime dir; one shared construction. */
export function supervisorPath(runtimeDir: string): string {
  return join(runtimeDir, 'pi-droid', 'supervisor.json');
}

/**
 * The children pidfile path under a runtime dir, beside the discovery record and
 * lock. Path construction only: `spawner.ts` owns the format (writer and
 * reader together).
 */
export function childrenPath(runtimeDir: string): string {
  return join(runtimeDir, 'pi-droid', 'children.json');
}

/**
 * True when `pid` exists. `EPERM` means the process exists but belongs to
 * another user, so it is alive. `ESRCH` (and anything else) means dead.
 */
export function isProcessAlive(
  pid: number,
  kill: (pid: number, signal?: number) => unknown = process.kill,
): boolean {
  try {
    kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM';
  }
}

export function ensureDiscoveryDir(runtimeDir: string): string {
  const dir = join(runtimeDir, 'pi-droid');
  const existing = lstatOrNull(dir);

  if (existing === null) {
    mkdirSync(dir, { recursive: true, mode: DISCOVERY_DIR_MODE });
    return dir;
  }
  // A symlink at this path would make `chmod` and the write land outside the
  // directory whose mode this module relies on. Mirrors `auth.ts`.
  if (existing.isSymbolicLink()) {
    throw new Error(`refusing to use a symlinked runtime directory: ${dir}`);
  }
  if (!existing.isDirectory()) {
    throw new Error(`runtime path is not a directory: ${dir}`);
  }
  if ((existing.mode & 0o077) !== 0) {
    chmodSync(dir, DISCOVERY_DIR_MODE);
  }
  return dir;
}

/** `lstat`, with only `ENOENT` meaning "not there yet"; other errors surface. */
function lstatOrNull(path: string): Stats | null {
  try {
    return lstatSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return null;
    }
    throw error;
  }
}

/**
 * Atomically publishes `record`: write a fresh temp file at `0600`, then
 * `rename` it over the target. The mode is set at creation, and `rename` is
 * atomic within a filesystem, so the target is never partially observable.
 */
export function writeDiscovery(runtimeDir: string, record: DiscoveryRecord): void {
  const dir = ensureDiscoveryDir(runtimeDir);
  const temp = join(dir, `supervisor.tmp.${randomBytes(6).toString('hex')}`);
  writeFileSync(temp, JSON.stringify(record), { mode: DISCOVERY_FILE_MODE });
  renameSync(temp, join(dir, 'supervisor.json'));
}

function parseRecord(raw: string): DiscoveryRecord | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return null;
  }
  const record = parsed as Record<string, unknown>;
  if (record.protocolVersion !== PROTOCOL_VERSION) return null;
  const { agentPort, viewerPort, pid, startedAt } = record;
  if (typeof pid !== 'number' || !Number.isSafeInteger(pid) || pid <= 0) return null;
  if (!isPort(agentPort) || !isPort(viewerPort)) return null;
  if (typeof startedAt !== 'string' || !Number.isFinite(Date.parse(startedAt))) {
    return null;
  }
  // `startedAt` is checked for parseability only, never range-checked: a
  // "sanity window" would reject a legitimately long-running hub. PID reuse
  // remains an accepted residual — a recycled pid reads as a live hub.
  return {
    agentPort,
    viewerPort,
    pid,
    startedAt,
    protocolVersion: record.protocolVersion,
  };
}

function isPort(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 1 && value <= 65535;
}

/**
 * Reads the discovery file, returning null for anything that is not a live,
 * current-version hub. Never throws.
 */
export function readDiscovery(
  runtimeDir: string,
  isAlive: (pid: number) => boolean = isProcessAlive,
): DiscoveryRecord | null {
  let raw: string;
  try {
    raw = readFileSync(supervisorPath(runtimeDir), 'utf8');
  } catch {
    return null;
  }
  const record = parseRecord(raw);
  if (record === null || !isAlive(record.pid)) {
    return null;
  }
  return record;
}

/**
 * Removes the discovery file if — and only if — it still names `pid`.
 *
 * Best-effort and idempotent: a missing file is fine, and a file naming a
 * different pid belongs to a hub that took over, so deleting it would strand
 * the winner. No throw, ever.
 */
export function removeDiscovery(runtimeDir: string, pid: number): void {
  const path = supervisorPath(runtimeDir);
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8')) as unknown;
    if (typeof parsed !== 'object' || parsed === null) return;
    if ((parsed as Record<string, unknown>).pid !== pid) return;
    unlinkSync(path);
  } catch {
    // Already gone, unreadable, or never there: nothing to do.
  }
}

/** The control-socket path under a runtime dir; one shared construction. */
export function controlSocketPath(runtimeDir: string): string {
  return join(runtimeDir, 'pi-droid', 'control.sock');
}

/** The exclusion lock path; one shared construction. */
export function lockPath(runtimeDir: string): string {
  return join(runtimeDir, 'pi-droid', 'supervisor.lock');
}

/** The result of trying to become the hub: we own it, or someone else does. */
export type LockResult = { ok: true } | { ok: false; holderPid: number | null };

/** Reads the pid from a lock file, or null when it is missing or unreadable. */
function readLockPid(path: string): number | null {
  try {
    const pid = Number(readFileSync(path, 'utf8').trim());
    return Number.isSafeInteger(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

/** Exclusive create: true on success, false when the lock already exists. */
function tryCreateLock(path: string, pid: number): boolean {
  let fd: number;
  try {
    fd = openSync(path, 'wx', LOCK_FILE_MODE);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') {
      return false;
    }
    throw error;
  }
  try {
    writeFileSync(fd, String(pid));
  } finally {
    closeSync(fd);
  }
  return true;
}

/**
 * Acquires the hub lock for `pid`, held for the process lifetime.
 *
 * Exclusion is the exclusive `open(..., 'wx')` create, not a check-then-act.
 * On `EEXIST` the holder is read: a dead holder's lock is reclaimed (unlink,
 * one retry); a live holder (or an unreadable lock — possibly mid-write) is
 * refused. `force` steals unconditionally for `--take-over`.
 *
 * PID reuse is an accepted residual: a recycled pid reads as a live holder, so
 * a legitimate fresh start after such a crash requires `--take-over`. No
 * process-start-time tiebreak is attempted.
 */
export function acquireLock(
  runtimeDir: string,
  pid: number,
  force = false,
): LockResult {
  ensureDiscoveryDir(runtimeDir);
  const path = lockPath(runtimeDir);

  if (force) {
    try {
      unlinkSync(path);
    } catch {
      // Nothing to steal: fine.
    }
    return tryCreateLock(path, pid) ? { ok: true } : { ok: false, holderPid: readLockPid(path) };
  }

  if (tryCreateLock(path, pid)) {
    return { ok: true };
  }

  // Leave an unreadable lock (e.g. a holder that has not written its pid yet)
  // alone: reclaiming it would hand the same lock to two processes.
  const holderPid = readLockPid(path);
  if (holderPid === null || isProcessAlive(holderPid)) {
    return { ok: false, holderPid };
  }

  try {
    unlinkSync(path);
  } catch {
    // A concurrent reclaimer got there first; the retry below decides.
  }
  return tryCreateLock(path, pid) ? { ok: true } : { ok: false, holderPid: readLockPid(path) };
}

/** Releases the lock only if it still names `pid`; idempotent, never throws. */
export function releaseLock(runtimeDir: string, pid: number): void {
  const path = lockPath(runtimeDir);
  try {
    if (readLockPid(path) !== pid) return;
    unlinkSync(path);
  } catch {
    // Already gone or unreadable: nothing to do.
  }
}

/** True when the lock still names `pid`. */
export function holdsLock(runtimeDir: string, pid: number): boolean {
  return readLockPid(lockPath(runtimeDir)) === pid;
}
