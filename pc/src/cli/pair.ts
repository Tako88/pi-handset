/**
 * `pi-droid pair` — ask the running hub for a pairing code and print it.
 *
 * Connects to the same-machine control socket, sends one request, and prints
 * the code (grouped, TTL stated), a scannable QR of the `pidroid://pair` URI,
 * and the phone-reachable addresses. Non-zero with a clear message when no hub
 * is running, or when a live hub's socket is unavailable.
 */

import { connect } from 'node:net';

import qrcodeTerminal from 'qrcode-terminal';

import {
  controlSocketPath,
  readDiscovery,
  resolveRuntimeDir,
} from '../hub/discovery.ts';
import { formatPairingUri } from '../protocol/pairing-uri.ts';
import type { PairingAddress } from '../protocol/pairing-uri.ts';
import { pairingCodeNotice } from './pairing-copy.ts';

/** The control channel's own version, deliberately not `PROTOCOL_VERSION`. */
const CONTROL_VERSION = 1;

export interface PairIo {
  stdout: (text: string) => void;
  stderr: (text: string) => void;
}

/** Test seams: a runtime dir override, an injected QR renderer, and a fetch bound. */
export interface PairDeps {
  runtimeDir?: string;
  renderQr?: (uri: string) => string;
  /** How long to wait for the hub's answer; overriding is for tests. */
  fetchTimeoutMs?: number;
}

/** A wedged hub must not hang `pair` forever. */
const DEFAULT_FETCH_TIMEOUT_MS = 10_000;

interface PairingResponse {
  ok?: unknown;
  error?: unknown;
  code?: unknown;
  expiresInMs?: unknown;
  viewerPort?: unknown;
  addresses?: unknown;
}

/**
 * `pair` takes no flags today. An unknown flag is an error (exit 2), never
 * silently ignored — mirroring `serve`'s parser.
 */
export function parsePairArgs(argv: readonly string[]): void {
  const arg = argv[0];
  if (arg !== undefined) throw new Error(`unknown option: ${arg}`);
}

function renderQrDefault(uri: string): string {
  let output = '';
  qrcodeTerminal.generate(uri, { small: true }, (qr) => {
    output = qr;
  });
  return output;
}

/** Sends one request and reads one response line. Rejects on connect failure. */
function fetchPairing(socketPath: string, timeoutMs: number): Promise<PairingResponse> {
  return new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    let data = '';
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const clearTimer = (): void => {
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
      }
    };
    socket.setEncoding('utf8');
    const fail = (error: Error): void => {
      if (settled) return;
      settled = true;
      clearTimer();
      socket.destroy();
      reject(error);
    };
    const done = (): void => {
      if (settled) return;
      settled = true;
      clearTimer();
      try {
        resolve(JSON.parse(data) as PairingResponse);
      } catch (error) {
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    };
    socket.on('connect', () => {
      socket.write(`${JSON.stringify({ v: CONTROL_VERSION, type: 'pair' })}\n`);
    });
    socket.on('data', (chunk) => {
      data += chunk.toString('utf8');
    });
    socket.on('end', done);
    socket.on('close', done);
    socket.on('error', fail);
    // Bound the whole fetch: a hub that accepts but never answers is wedged.
    // `unref` so a pending timer can never keep the process alive by itself.
    timer = setTimeout(() => fail(new Error('timed out waiting for the hub')), timeoutMs);
    timer.unref();
  });
}

function addressLine(kind: PairingAddress['kind'], host: string, port: number): string {
  const label = kind === 'lan' ? 'Home network' : 'Tailscale';
  return `  ${label.padEnd(12)} ${host}:${port}\n`;
}

export async function runPair(
  argv: readonly string[],
  io: PairIo,
  deps: PairDeps = {},
): Promise<number> {
  try {
    parsePairArgs(argv);
  } catch (error) {
    io.stderr(`pi-droid pair: ${(error as Error).message}\n`);
    return 2;
  }

  const runtimeDir = deps.runtimeDir ?? resolveRuntimeDir();
  const socketPath = controlSocketPath(runtimeDir);

  let response: PairingResponse;
  try {
    response = await fetchPairing(
      socketPath,
      deps.fetchTimeoutMs ?? DEFAULT_FETCH_TIMEOUT_MS,
    );
  } catch {
    // A refused connect with no live record means no hub; with one, the hub is
    // shutting down or wedged (the control socket is started before the
    // record is published, so a live record implies a listening socket).
    const record = readDiscovery(runtimeDir);
    if (record === null) {
      io.stderr('pi-droid pair: no hub is running\n');
    } else {
      io.stderr(
        `pi-droid pair: a hub is running (pid ${record.pid}) but its control ` +
          `socket is unavailable; restart it\n`,
      );
    }
    return 1;
  }

  if (response.ok !== true || typeof response.code !== 'string') {
    const reason =
      typeof response.error === 'string' ? response.error : 'the hub refused the request';
    io.stderr(`pi-droid pair: ${reason}\n`);
    return 1;
  }

  const expiresInMs =
    typeof response.expiresInMs === 'number' ? response.expiresInMs : 5 * 60_000;
  const viewerPort =
    typeof response.viewerPort === 'number' ? response.viewerPort : null;
  const addresses = Array.isArray(response.addresses)
    ? (response.addresses as PairingAddress[])
    : [];

  let uri: string;
  try {
    uri = formatPairingUri({
      code: response.code,
      viewerPort,
      addresses,
    });
  } catch {
    // `ok:true` but a payload this build cannot render (an address that does
    // not classify, an unusable port). Report it, never crash out of `runPair`.
    io.stderr('pi-droid pair: the hub sent an invalid pairing payload\n');
    return 1;
  }

  io.stdout(pairingCodeNotice(response.code, expiresInMs));
  io.stdout('Scan to pair:\n');
  io.stdout((deps.renderQr ?? renderQrDefault)(uri));
  io.stdout(`\n${uri}\n`);

  if (addresses.length === 0) {
    io.stdout(
      'pi-droid pair: no addresses to advertise ' +
        '(the hub was started with --no-lan, or has no LAN or Tailscale address)\n',
    );
    return 0;
  }

  io.stdout(`Reachable at port ${viewerPort}:\n`);
  for (const address of addresses) {
    io.stdout(addressLine(address.kind, address.host, viewerPort ?? 0));
  }
  return 0;
}
