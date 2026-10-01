/**
 * `pi-droid serve` — the supervisor process.
 *
 * Parse the flags, take the exclusion lock (see `acquireLock`), refuse to start
 * while another live supervisor holds it (unless `--take-over`), load the
 * persisted token, start the hub's two listeners, publish the discovery record
 * with the real ports, and stay alive until a signal.
 *
 * The lock is the exclusion primitive; the discovery file is only the published
 * record. Taking the lock *before* touching the record is what makes two
 * simultaneous starts exclusive — a check-then-write of the record is not.
 *
 * `--port` is the viewer port (default 8787); `--no-lan` binds that listener to
 * loopback instead of `0.0.0.0`. The lock and record are released on `SIGINT`/
 * `SIGTERM`, but only while we still hold the lock, so a taken-over hub cannot
 * delete its successor's record.
 *
 * `console.*` is avoided in the library; stderr writes here are the CLI's job.
 */

import { pathToFileURL } from 'node:url';

import { loadOrCreateToken, resolveConfigDir } from '../hub/auth.ts';
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
import { createHub } from '../hub/hub.ts';
import { TICKET_TTL_MS, createTicketStore } from '../hub/pairing.ts';
import { createSpawner } from '../hub/spawner.ts';
import { PROTOCOL_VERSION } from '../protocol/protocol.ts';

/** The viewer listener's default port. */
export const DEFAULT_PORT = 8787;

export interface ServeArgs {
  port: number;
  /** False binds the viewer listener to loopback instead of `0.0.0.0`. */
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

function warn(message: string): void {
  process.stderr.write(`pi-droid serve: ${message}\n`);
}

/**
 * The startup hint: how to ask for a pairing code. It names the exact signal
 * and pid because the phone cannot read the token file, so this line is the
 * only path from a fresh device to a code.
 */
export function pairingHint(pid: number): string {
  return (
    `pi-droid serve: ready. Pair a phone: run \`kill -USR1 ${pid}\` to print a ` +
    `pairing code (valid for ${TICKET_TTL_MS / 60_000} minutes).\n`
  );
}

/** Printed in response to SIGUSR1. The code is grouped for reading; TTL stated. */
export function pairingCodeNotice(code: string): string {
  return `pi-droid pairing code: ${code} (valid for ${TICKET_TTL_MS / 60_000} minutes)\n`;
}

/**
 * The announcement for a pairing request, or null while shutting down. Once
 * teardown has begun the hub is closing or closed, so a code minted now could
 * never be redeemed — printing one would be a lie. `issue` is called only when
 * the announcement is allowed.
 */
export function pairingAnnouncement(
  shuttingDown: boolean,
  issue: () => string,
): string | null {
  if (shuttingDown) return null;
  return pairingCodeNotice(issue());
}

/**
 * Closes the hub and releases the record and lock, returning the process exit
 * code. A failing `close()` is a real error: the signal handler must never let
 * it become an unhandled rejection, and the process must exit non-zero.
 */
export async function finishShutdown(
  hub: { close(): Promise<void> },
  runtimeDir: string,
  pid: number,
): Promise<number> {
  try {
    await hub.close();
  } catch (error) {
    process.stderr.write(
      `pi-droid serve: shutdown failed: ${(error as Error).message}\n`,
    );
    return 1;
  }
  // Remove the record only while we still hold the lock: a `--take-over`
  // winner has replaced lock and record, and deleting its record would strand
  // it. A residual microsecond window remains between this check and the
  // unlink — an unlink cannot be atomic with a lock check. The pid check
  // inside `removeDiscovery` is the backstop.
  if (holdsLock(runtimeDir, pid)) {
    removeDiscovery(runtimeDir, pid);
  }
  releaseLock(runtimeDir, pid);
  return 0;
}

async function main(): Promise<void> {
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
        `(pid ${existing.pid}, viewer port ${existing.viewerPort}); ` +
        `use --take-over to replace it`,
      1,
    );
    return;
  }

  let token: string;
  try {
    const loaded = loadOrCreateToken(resolveConfigDir());
    token = loaded.token;
    if (loaded.regenerated) {
      warn('a new pairing token was written; previously paired phones are de-paired');
    }
    if (loaded.insecureParent) {
      warn('the config directory is group- or world-writable; the token may be replaceable');
    }
  } catch (error) {
    releaseLock(runtimeDir, process.pid);
    refuse((error as Error).message, 2);
    return;
  }

  let hub: Awaited<ReturnType<typeof createHub>>;
  // One store, shared with the hub: the handler below mints from the *same*
  // instance the hub redeems from. A fresh `createTicketStore()` there would
  // print codes the hub cannot exchange — the printed-but-unredeemable bug
  // this milestone fixes.
  const tickets = createTicketStore();
  // One supervisor per serve: the hub owns the spawner and closes it on a
  // graceful stop, group-killing every app-started child.
  const spawner = createSpawner();
  try {
    hub = await createHub({
      token,
      tickets,
      viewerPort: args.port,
      viewerHost: args.lan ? '0.0.0.0' : '127.0.0.1',
      spawner,
    });
  } catch (error) {
    releaseLock(runtimeDir, process.pid);
    refuse(
      `could not start the listeners on port ${args.port}: ${(error as Error).message}`,
      1,
    );
    return;
  }

  // Declared before the SIGUSR1 handler so a signal arriving after teardown has
  // begun is seen as shutting down and mints nothing (`pairingAnnouncement`).
  let shuttingDown = false;

  // Installed before the discovery file is written, so a reader that sees the
  // record is guaranteed the handler exists. Printed on demand, never at
  // startup: a ticket lives only TICKET_TTL_MS, so one minted at launch would
  // usually expire before the user reached the phone.
  process.on('SIGUSR1', () => {
    const announcement = pairingAnnouncement(shuttingDown, () => tickets.issue());
    if (announcement !== null) process.stdout.write(announcement);
  });

  try {
    writeDiscovery(runtimeDir, {
      agentPort: hub.agentPort,
      viewerPort: hub.viewerPort,
      pid: process.pid,
      startedAt: new Date().toISOString(),
      protocolVersion: PROTOCOL_VERSION,
    });
  } catch (error) {
    await hub.close();
    releaseLock(runtimeDir, process.pid);
    refuse((error as Error).message, 2);
    return;
  }

  process.stdout.write(pairingHint(process.pid));

  const shutdown = async (): Promise<void> => {
    // Single-shot: a second signal must not re-enter teardown. Any close()
    // rejection is caught inside `finishShutdown`, so this never becomes an
    // unhandled rejection.
    if (shuttingDown) return;
    shuttingDown = true;
    process.exitCode = await finishShutdown(hub, runtimeDir, process.pid);
  };
  process.on('SIGINT', () => {
    void shutdown();
  });
  process.on('SIGTERM', () => {
    void shutdown();
  });

  // The listeners keep the process alive until a signal.
}

if (
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  void main();
}
