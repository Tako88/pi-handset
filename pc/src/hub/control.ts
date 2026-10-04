/**
 * The same-machine control socket.
 *
 * A Unix domain socket at `<runtimeDir>/pi-droid/control.sock` (`0600`, inside
 * the `0700` discovery dir). `pi-droid pair` connects, sends one newline-
 * delimited JSON request, reads one newline-delimited response, and the server
 * closes. No TCP, no auth beyond filesystem permission: any same-UID process
 * can already read the token file, so this adds no exposure.
 *
 * The socket file lifecycle is self-contained here:
 *   - the parent dir is ensured `0700` (reusing `ensureDiscoveryDir`);
 *   - the listener binds a *unique temp path*, which is then `rename`d onto the
 *     canonical path and `chmod`ed `0600`; the inode is recorded after rename.
 *   - `close()` unlinks only when the current entry is still that inode and is
 *     not a symlink — a `--take-over` loser closing after the winner rebound a
 *     new socket leaves the winner's file alone.
 *
 * Why bind-temp-then-rename rather than bind-the-path directly: libuv records
 * the path passed to `bind` and `unlink`s it on close, unconditionally. Binding
 * the canonical path therefore means any later `close()` deletes whatever file
 * currently sits there — including a `--take-over` winner's. The rename leaves
 * libuv's recorded path pointing at a name that no longer exists, so the inode
 * guard below is the only thing that can remove the canonical file.
 */

import { chmodSync, lstatSync, renameSync, unlinkSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { createServer } from 'node:net';
import { networkInterfaces } from 'node:os';
import type { NetworkInterfaceInfo } from 'node:os';
import type { Server, Socket } from 'node:net';

import { enumerateAddresses } from './addresses.ts';
import { controlSocketPath, ensureDiscoveryDir } from './discovery.ts';
import { TICKET_TTL_MS, normalizeTicket } from './pairing.ts';
import type { PairingAddress } from '../protocol/pairing-uri.ts';

/** Local to the control channel; intentionally NOT `PROTOCOL_VERSION`. */
export const CONTROL_PROTOCOL_VERSION = 1;
/** A same-UID process must not be able to make the hub buffer unboundedly. */
export const MAX_CONTROL_REQUEST_BYTES = 4096;
/** A client that connects and sends nothing is dropped after this. */
export const DEFAULT_CONTROL_REQUEST_TIMEOUT_MS = 3000;

export interface ControlServerOptions {
  runtimeDir: string;
  /** The hub's viewer port; advertised only when addresses are. */
  viewerPort: number;
  /** False (`--no-lan`) advertises no addresses at all. */
  lan: boolean;
  /** Mints a ticket, or null while shutting down. Must not throw; if it does,
   * the request is refused rather than crashing the connection handler. */
  mint: () => string | null;
  /** Injected interface map; defaults to the real `os.networkInterfaces()`. */
  interfaces?: NodeJS.Dict<NetworkInterfaceInfo[]>;
  requestTimeoutMs?: number;
}

export interface ControlServer {
  close(): Promise<void>;
}

interface FuturePairing {
  v: 1;
  type: 'pairing';
  ok: boolean;
  error?: string;
  code?: string;
  expiresInMs?: number;
  viewerPort?: number | null;
  addresses?: PairingAddress[];
}

function failure(error: string): FuturePairing {
  return { v: CONTROL_PROTOCOL_VERSION, type: 'pairing', ok: false, error };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export async function createControlServer(
  options: ControlServerOptions,
): Promise<ControlServer> {
  ensureDiscoveryDir(options.runtimeDir);
  const path = controlSocketPath(options.runtimeDir);

  // A unique temp name in the same dir: the canonical path is replaced by a
  // `rename` after listening, so a crashed hub's stale socket is reclaimed and
  // libuv's close-time unlink never targets the canonical name.
  const tempPath = `${path}.${process.pid}.${randomBytes(6).toString('hex')}`;
  const interfaces = options.interfaces ?? networkInterfaces();
  const requestTimeoutMs =
    options.requestTimeoutMs ?? DEFAULT_CONTROL_REQUEST_TIMEOUT_MS;

  const respond = (raw: string): FuturePairing => {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return failure('malformed request');
    }
    if (!isRecord(parsed)) return failure('malformed request');
    if (parsed.v !== CONTROL_PROTOCOL_VERSION) {
      return failure('unsupported control protocol version');
    }
    if (parsed.type !== 'pair') return failure('unknown request type');

    // `mint` is documented not to throw, but a throw here must not become an
    // uncaught rejection in the connection handler.
    let minted: string | null;
    try {
      minted = options.mint();
    } catch {
      minted = null;
    }
    const code = minted === null ? null : normalizeTicket(minted);
    if (code === null) return failure('cannot mint');

    const addresses = options.lan ? enumerateAddresses(interfaces) : [];
    return {
      v: CONTROL_PROTOCOL_VERSION,
      type: 'pairing',
      ok: true,
      code,
      expiresInMs: TICKET_TTL_MS,
      viewerPort: addresses.length > 0 ? options.viewerPort : null,
      addresses,
    };
  };

  const sockets = new Set<Socket>();
  const server: Server = createServer((socket) => {
    sockets.add(socket);
    socket.setEncoding('utf8');
    let buffer = '';
    let settled = false;

    // Never keep the process alive for an idle client, and `unref()` so this
    // timer cannot make the serve lifecycle test flaky.
    const timeout = setTimeout(() => socket.destroy(), requestTimeoutMs);
    timeout.unref();

    const finish = (response: FuturePairing | null): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      sockets.delete(socket);
      if (response === null) {
        socket.destroy();
        return;
      }
      socket.end(`${JSON.stringify(response)}\n`);
    };

    socket.on('data', (chunk: string) => {
      if (settled) return;
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline === -1) {
        if (buffer.length > MAX_CONTROL_REQUEST_BYTES) {
          finish(failure('request too large'));
        }
        return;
      }
      const line = buffer.slice(0, newline);
      finish(
        line.length > MAX_CONTROL_REQUEST_BYTES
          ? failure('request too large')
          : respond(line),
      );
    });
    socket.on('error', () => finish(null));
    socket.on('close', () => {
      clearTimeout(timeout);
      sockets.delete(socket);
    });
  });

  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error): void => reject(error);
    server.once('error', onError);
    server.listen(tempPath, () => {
      server.removeListener('error', onError);
      resolve();
    });
  });

  // Atomic replace of any stale file (or symlink) at the canonical path; a
  // directory in the way makes this throw, which is the documented startup
  // failure. The temp file is inside the same `0700` dir, so the rename cannot
  // cross filesystems. Any failure here (rename, chmod, lstat) must leave no
  // listener and no canonical socket file behind: close the listener, which
  // reclaims the temp path (libuv unlinks its recorded name), and remove the
  // canonical file if the rename already landed.
  let recordedIno: number;
  try {
    renameSync(tempPath, path);
    chmodSync(path, 0o600);
    recordedIno = lstatSync(path).ino;
  } catch (error) {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    try {
      unlinkSync(path);
    } catch {
      // Never mind: the startup failure is already being reported.
    }
    throw error;
  }
  let closed = false;

  return {
    async close(): Promise<void> {
      if (closed) return;
      closed = true;
      for (const socket of sockets) socket.destroy();
      sockets.clear();
      await new Promise<void>((resolve) => server.close(() => resolve()));

      // Inode-guarded unlink. `lstat`, never `stat`: `stat` follows a symlink
      // and would compare the wrong inode. ENOENT means someone already
      // removed it — success, not an error.
      let current;
      try {
        current = lstatSync(path);
      } catch {
        return;
      }
      if (current.isSymbolicLink()) return;
      if (current.ino !== recordedIno) return;
      try {
        unlinkSync(path);
      } catch {
        // Best-effort: a race with a takeover is not this server's problem.
      }
    },
  };
}
