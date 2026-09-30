/**
 * `pi-droid serve` — the supervisor process.
 *
 * This milestone owns the discovery file and the exclusion lock: parse the
 * flags, take the lock (see `acquireLock`), refuse to start while another live
 * supervisor holds it (unless `--take-over`), write our record, and stay alive
 * until a signal. The two listeners arrive in M5 and replace the idle interval.
 *
 * The lock is the exclusion primitive; the discovery file is only the published
 * record. Taking the lock *before* touching the record is what makes two
 * simultaneous starts exclusive — a check-then-write of the record is not.
 *
 * `--port` is the viewer port (default 8787); `--no-lan` will disable the
 * LAN-visible listener in M5. The lock and record are released on `SIGINT`/
 * `SIGTERM`, but only while we still hold the lock, so a taken-over hub cannot
 * delete its successor's record.
 *
 * `console.*` is avoided in the library; stderr writes here are the CLI's job.
 */

import { pathToFileURL } from 'node:url';

import {
  acquireLock,
  holdsLock,
  readDiscovery,
  releaseLock,
  removeDiscovery,
  resolveRuntimeDir,
  writeDiscovery,
} from '../hub/discovery.ts';
import type { LockResult } from '../hub/discovery.ts';
import { PROTOCOL_VERSION } from '../protocol/protocol.ts';

/** The viewer listener's default port. */
export const DEFAULT_PORT = 8787;

export interface ServeArgs {
  port: number;
  /** Inert until M5: the LAN listener does not exist yet, so this changes nothing. */
  lan: boolean;
  takeOver: boolean;
}

function parsePort(value: string): number {
  // Digits only: `Number()` would accept `0x10`, `1e3`, `9000.0` and
  // surrounding whitespace, all of which are port typos rather than ports.
  if (!/^[0-9]+$/.test(value)) {
    throw new Error(`--port must be an integer between 1 and 65535, got: ${value}`);
  }
  const port = Number(value);
  if (!Number.isSafeInteger(port) || port < 1 || port > 65535) {
    throw new Error(`--port must be an integer between 1 and 65535, got: ${value}`);
  }
  return port;
}

/**
 * A pure flag parser. Unknown flags are an error, never silently ignored:
 * a typo'd `--no-lna` must not quietly expose the viewer port to the LAN.
 * `--port=9000` is deliberately unsupported, not silently accepted.
 */
export function parseArgs(argv: readonly string[]): ServeArgs {
  const args: ServeArgs = { port: DEFAULT_PORT, lan: true, takeOver: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    switch (arg) {
      case '--port': {
        const value = argv[++i];
        if (value === undefined) throw new Error('--port requires a value');
        args.port = parsePort(value);
        break;
      }
      case '--no-lan':
        args.lan = false;
        break;
      case '--take-over':
        args.takeOver = true;
        break;
      default:
        throw new Error(`unknown option: ${arg}`);
    }
  }
  return args;
}

function refuse(message: string, code: number): void {
  process.stderr.write(`pi-droid serve: ${message}\n`);
  process.exitCode = code;
}

function main(): void {
  let args: ServeArgs;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    refuse((error as Error).message, 2);
    return;
  }

  const runtimeDir = resolveRuntimeDir();

  let lock: LockResult;
  try {
    lock = acquireLock(runtimeDir, process.pid, args.takeOver);
  } catch (error) {
    // Startup-fatal: a symlinked/non-directory runtime path or unwritable dir.
    refuse((error as Error).message, 2);
    return;
  }

  if (!lock.ok) {
    refuse(
      `another supervisor is already running` +
        (lock.holderPid === null ? '' : ` (pid ${lock.holderPid})`) +
        `; use --take-over to replace it`,
      1,
    );
    return;
  }

  // We hold the lock, so the record is ours. A *live* record that does not
  // belong to us is inconsistent state (the lock is the authority); refuse
  // rather than strand it. `--take-over` overrides. A stale record (dead pid,
  // corrupt JSON, version mismatch) reads as null here and is simply replaced.
  const existing = args.takeOver ? null : readDiscovery(runtimeDir);
  if (existing !== null) {
    releaseLock(runtimeDir, process.pid);
    refuse(
      `another supervisor is already running ` +
        `(pid ${existing.pid}, port ${existing.port}); ` +
        `use --take-over to replace it`,
      1,
    );
    return;
  }

  try {
    writeDiscovery(runtimeDir, {
      port: args.port,
      pid: process.pid,
      startedAt: new Date().toISOString(),
      protocolVersion: PROTOCOL_VERSION,
    });
  } catch (error) {
    releaseLock(runtimeDir, process.pid);
    refuse((error as Error).message, 2);
    return;
  }

  let shuttingDown = false;
  const keepAlive = setInterval(() => {}, 2 ** 31 - 1);

  const shutdown = (): void => {
    // Single-shot: a second signal must not re-enter teardown.
    if (shuttingDown) return;
    shuttingDown = true;
    // M5 seam: replace this synchronous teardown with an async close that
    // drains both listeners (`await server.close()`), then exit.
    clearInterval(keepAlive);
    // Remove the record only while we still hold the lock: a `--take-over`
    // winner has replaced lock and record, and deleting its record would strand
    // it. A residual microsecond window remains between this check and the
    // unlink — an unlink cannot be atomic with a lock check. The pid check
    // inside `removeDiscovery` is the backstop.
    if (holdsLock(runtimeDir, process.pid)) {
      removeDiscovery(runtimeDir, process.pid);
    }
    releaseLock(runtimeDir, process.pid);
    process.exitCode = 0;
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

  // Stay alive until a signal; M5 swaps this for the listeners.
}

if (
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main();
}
