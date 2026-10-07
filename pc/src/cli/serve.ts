/**
 * `pi-handset serve` — the supervisor process.
 *
 * Parse the flags, take the exclusion lock (see `acquireLock`), refuse to start
 * while another live supervisor holds it (unless `--take-over`), load the
 * persisted token, start the hub's two listeners and the control socket,
 * publish the discovery record with the real ports, and stay alive until a
 * signal.
 *
 * The lock is the exclusion primitive; the discovery file is only the published
 * record. Taking the lock *before* touching the record is what makes two
 * simultaneous starts exclusive — a check-then-write of the record is not.
 *
 * `--port` is the viewer port (default 8787); `--no-lan` binds that listener to
 * loopback instead of `0.0.0.0`. The lock, record and control socket are
 * released on `SIGINT`/`SIGTERM`, but the record only while we still hold the
 * lock, so a taken-over hub cannot delete its successor's record.
 *
 * `console.*` is avoided in the library; stderr writes here are the CLI's job.
 */

import { fileURLToPath, pathToFileURL } from 'node:url';

import { createControlServer } from '../hub/control.ts';
import type { ControlServer } from '../hub/control.ts';
import { loadOrCreateToken, resolveConfigDir } from '../hub/auth.ts';
import {
  acquireLock,
  childrenPath,
  holdsLock,
  readDiscovery,
  releaseLock,
  removeDiscovery,
  resolveRuntimeDir,
  writeDiscovery,
} from '../hub/discovery.ts';
import type { LockResult } from '../hub/discovery.ts';
import { createHub } from '../hub/hub.ts';
import { TICKET_TTL_MS, createTicketStore, normalizeTicket } from '../hub/pairing.ts';
import { DEFAULT_MAX_SESSIONS, createSpawner, reapOrphans } from '../hub/spawner.ts';
import { PROTOCOL_VERSION } from '../protocol/protocol.ts';

/** The viewer listener's default port. */
export const DEFAULT_PORT = 8787;

export interface ServeArgs {
  port: number;
  /** False binds the viewer listener to loopback instead of `0.0.0.0`. */
  lan: boolean;
  takeOver: boolean;
  /** The most app-started sessions the supervisor may spawn at once. */
  maxSessions: number;
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

function parseMaxSessions(value: string): number {
  // Digits only, same reasoning as `parsePort`: `Number()` would accept `0x10`,
  // `1e3` and `2.5`. A cap of zero makes the app useless and is almost
  // certainly a typo, so the floor is one.
  if (!/^[0-9]+$/.test(value)) {
    throw new Error(`--max-sessions must be a positive integer, got: ${value}`);
  }
  const count = Number(value);
  if (!Number.isSafeInteger(count) || count < 1) {
    throw new Error(`--max-sessions must be a positive integer, got: ${value}`);
  }
  return count;
}

/**
 * A pure flag parser. Unknown flags are an error, never silently ignored:
 * a typo'd `--no-lna` must not quietly expose the viewer port to the LAN.
 * `--port=9000` is deliberately unsupported, not silently accepted.
 */
export function parseArgs(argv: readonly string[]): ServeArgs {
  const args: ServeArgs = {
    port: DEFAULT_PORT,
    lan: true,
    takeOver: false,
    maxSessions: DEFAULT_MAX_SESSIONS,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
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
      case '--max-sessions': {
        const value = argv[++i];
        if (value === undefined) throw new Error('--max-sessions requires a value');
        args.maxSessions = parseMaxSessions(value);
        break;
      }
      default:
        throw new Error(`unknown option: ${arg}`);
    }
  }
  return args;
}

/** Writes the refusal and returns the exit code; the caller returns it. */
function refuse(message: string, code: number): number {
  process.stderr.write(`pi-handset serve: ${message}\n`);
  return code;
}

function warn(message: string): void {
  process.stderr.write(`pi-handset serve: ${message}\n`);
}

/**
 * The startup hint: how to ask for a pairing code. It names the absolute
 * `main.ts` path so it is runnable from any cwd before #37 installs the
 * `pi-handset` bin. The phone cannot read the token file, so this line is the
 * only path from a fresh device to a code.
 */
export function pairingHint(mainPath: string): string {
  return (
    `pi-handset serve: ready. Pair a phone: run \`node ${mainPath} pair\` to print a ` +
    `code and QR (valid for ${TICKET_TTL_MS / 60_000} minutes).\n`
  );
}

/** Printed in response to SIGUSR1. The code is grouped for reading; TTL stated. */
export function pairingCodeNotice(code: string): string {
  return `pi-handset pairing code: ${code} (valid for ${TICKET_TTL_MS / 60_000} minutes)\n`;
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
      `pi-handset serve: shutdown failed: ${(error as Error).message}\n`,
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

/**
 * A mid-startup failure after the hub (and optionally the control socket) is
 * live: tear both down, release the lock, and report the tabled exit code. A
 * rejecting `close` must NOT skip the lock release or the refusal — the
 * original startup error is what gets reported, and an unreleased lock would
 * strand the next `serve`. Never throws.
 */
export async function abortStartup(
  hub: { close(): Promise<void> },
  runtimeDir: string,
  pid: number,
  message: string,
  code: number,
  control?: { close(): Promise<void> },
): Promise<number> {
  try {
    await hub.close();
  } catch {
    // Best-effort: report the original startup error, not the close failure.
  }
  if (control !== undefined) {
    try {
      await control.close();
    } catch {
      // Best-effort, same reasoning.
    }
  }
  releaseLock(runtimeDir, pid);
  return refuse(message, code);
}

/**
 * Runs one serve process to completion, returning its exit code.
 *
 * Startup refusals return their code directly (see the exit-code table in the
 * pairing-35 plan). On the success path this returns a promise that resolves
 * only on the first `SIGINT`/`SIGTERM`: the teardown is single-shot
 * (`shuttingDown` is set first, so `mint` refuses and SIGUSR1 mints nothing),
 * then `control.close()`, then `finishShutdown`, whose code resolves the
 * promise. The handler is armed the moment the lock is ours — before the control
 * socket, the record or the hint is written — so a stop during startup unwinds
 * at the next checkpoint instead of killing the process and stranding them. The
 * listeners keep the process alive until that signal.
 */
export async function runServe(argv: readonly string[]): Promise<number> {
  let args: ServeArgs;
  try {
    args = parseArgs(argv);
  } catch (error) {
    return refuse((error as Error).message, 2);
  }

  const runtimeDir = resolveRuntimeDir();

  let lock: LockResult;
  try {
    lock = acquireLock(runtimeDir, process.pid, args.takeOver);
  } catch (error) {
    // Startup-fatal: a symlinked/non-directory runtime path or unwritable dir.
    return refuse((error as Error).message, 2);
  }

  if (!lock.ok) {
    return refuse(
      `another supervisor is already running` +
        (lock.holderPid === null ? '' : ` (pid ${lock.holderPid})`) +
        `; use --take-over to replace it`,
      1,
    );
  }

  // Armed here — the lock is ours, and nothing else is written yet — because a
  // signal from this point on must run the teardown rather than kill the
  // process, or the lock, the control socket and the discovery record outlive
  // it. Until `teardown` is assigned (once serving) a stop only sets the flag,
  // and the startup path checks it after each `await`. Arming it later, after
  // the record was published, left a window in which a SIGTERM exited on the
  // signal and stranded `control.sock` — CI caught exactly that.
  //
  // `shuttingDown` is also what makes SIGUSR1 mint nothing: a code minted after
  // a stop has begun could never be redeemed (`pairingAnnouncement`).
  let shuttingDown = false;
  let teardown: (() => Promise<void>) | null = null;
  let teardownStarted = false;
  const requestStop = (): void => {
    shuttingDown = true;
    void teardown?.();
  };
  process.on('SIGINT', requestStop);
  process.on('SIGTERM', requestStop);

  // We hold the lock, so the record is ours. A *live* record that does not
  // belong to us is inconsistent state (the lock is the authority); refuse
  // rather than strand it. `--take-over` overrides. A stale record (dead pid,
  // corrupt JSON, version mismatch) reads as null here and is simply replaced.
  const existing = args.takeOver ? null : readDiscovery(runtimeDir);
  if (existing !== null) {
    releaseLock(runtimeDir, process.pid);
    return refuse(
      `another supervisor is already running ` +
        `(pid ${existing.pid}, viewer port ${existing.viewerPort}); ` +
        `use --take-over to replace it`,
      1,
    );
  }

  // Reap the children a previous, hard-killed hub left behind, before this
  // boot's spawner can add its own records. Skipped under `--take-over`: the
  // previous hub may still be alive, so its children are not orphans. The
  // reaper never throws and never aborts startup.
  if (!args.takeOver) {
    const reaped = reapOrphans(childrenPath(runtimeDir), warn);
    if (reaped > 0) {
      warn(`reaped ${reaped} orphaned session(s) from a previous run`);
    }
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
    return refuse((error as Error).message, 2);
  }

  let hub: Awaited<ReturnType<typeof createHub>>;
  // One store, shared with the hub and the control socket: both mint from the
  // *same* instance the hub redeems from. A fresh `createTicketStore()` there
  // would print codes the hub cannot exchange — the printed-but-unredeemable
  // bug this milestone fixes.
  const tickets = createTicketStore();
  // One supervisor per serve: the hub owns the spawner and closes it on a
  // graceful stop, group-killing every app-started child.
  const spawner = createSpawner({
    maxSessions: args.maxSessions,
    pidFile: childrenPath(runtimeDir),
    // One switch for the whole diagnostic chain: the bridge writes its socket
    // close codes only under PI_HANDSET_DEBUG, and the spawner drains the child's
    // pipes, so without a sink here those lines reach nobody.
    ...(process.env.PI_HANDSET_DEBUG === '1'
      ? { debug: (text: string) => process.stderr.write(text) }
      : {}),
  });
  try {
    hub = await createHub({
      token,
      tickets,
      viewerPort: args.port,
      viewerHost: args.lan ? '0.0.0.0' : '127.0.0.1',
      spawner,
      onHandlerError: (error) =>
        warn(`a message handler failed: ${error instanceof Error ? error.message : String(error)}`),
    });
  } catch (error) {
    releaseLock(runtimeDir, process.pid);
    return refuse(
      `could not start the listeners on port ${args.port}: ${(error as Error).message}`,
      1,
    );
  }

  // A stop requested while the hub was being built: nothing has been published
  // yet, so the hub is the only thing to close.
  if (shuttingDown) {
    return await finishShutdown(hub, runtimeDir, process.pid);
  }

  // Started BEFORE `writeDiscovery` (R2.7): if the record is visible, the
  // socket is already listening, so `pair` never sees a live record with a
  // not-yet-listening socket. `mint` mints from the SAME store the hub
  // redeems from; no `!`, and the control handler turns a throw into a refusal.
  let control: ControlServer;
  try {
    control = await createControlServer({
      runtimeDir,
      viewerPort: args.port,
      lan: args.lan,
      mint: () => (shuttingDown ? null : normalizeTicket(tickets.issue()) ?? null),
    });
  } catch (error) {
    return await abortStartup(
      hub,
      runtimeDir,
      process.pid,
      `could not start the control socket: ${(error as Error).message}`,
      1,
    );
  }

  // A stop requested while the socket was being created: the socket exists now,
  // so startup owes it the same close a signal would have run.
  if (shuttingDown) {
    try {
      await control.close();
    } catch {
      // Best-effort, as in the teardown below.
    }
    return await finishShutdown(hub, runtimeDir, process.pid);
  }

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
    return await abortStartup(
      hub,
      runtimeDir,
      process.pid,
      (error as Error).message,
      2,
      control,
    );
  }

  process.stdout.write(
    pairingHint(fileURLToPath(new URL('./main.ts', import.meta.url))),
  );

  return await new Promise<number>((resolve) => {
    teardown = async (): Promise<void> => {
      // Single-shot: a second signal must not re-enter teardown. Any close()
      // rejection is caught here, so this never becomes an unhandled rejection.
      if (teardownStarted) return;
      teardownStarted = true;
      try {
        await control.close();
      } catch {
        // Best-effort: teardown must still reach `finishShutdown`.
      }
      resolve(await finishShutdown(hub, runtimeDir, process.pid));
    };
    // A stop requested while the record was being written: nothing was awaiting
    // the promise yet, so run the teardown the signal would have run.
    if (shuttingDown) void teardown();
  });
}

if (
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  void runServe(process.argv.slice(2)).then((code) => {
    process.exitCode = code;
  });
}
