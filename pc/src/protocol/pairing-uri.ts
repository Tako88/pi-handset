/**
 * The `pidroid://pair` payload — a cross-platform contract shared with the
 * Android scanner (#36). Pure: no I/O, no clock, no randomness.
 *
 * Grammar (pinned in `protocol/fixtures/pairing/vectors.json`):
 *
 *   pidroid://pair?v=1&code=ABCD2345[&port=8787][&lan=…][&ts=…]
 *
 * `v` is required and must be `"1"`; a missing or future `v` is reported as
 * `unsupported-version` so the scanner can say "update the app" rather than
 * "not a pairing code". `code` is normalized through `normalizeTicket`, so a
 * dashed/lowercase code is accepted and always returned canonical.
 * `port` is present iff at least one address is present, and each address value
 * must classify to its own param kind — the app labels by param, so
 * `lan=8.8.8.8` would otherwise show "Home network" for a public IP.
 * Unknown params are ignored (forward compatibility); params are
 * case-sensitive, so `LAN=` is not `lan=`.
 */

import { isIPv4 } from 'node:net';

import { normalizeTicket } from '../hub/pairing.ts';

export type AddressKind = 'lan' | 'ts';

export interface PairingAddress {
  kind: AddressKind;
  host: string;
}

export interface PairingPayload {
  /** Canonical 8-character ticket, no dash. */
  code: string;
  /** The viewer port, or null when there are no addresses. */
  viewerPort: number | null;
  addresses: PairingAddress[];
}

export type PairingError =
  | 'not-a-pairing-uri'
  | 'unsupported-version'
  | 'invalid-pairing-uri';

export type PairingParseResult =
  | { ok: true; pairing: PairingPayload }
  | { ok: false; error: PairingError };

export const PAIRING_PROTOCOL_VERSION = 1;

function isLan(host: string): boolean {
  if (!isIPv4(host)) return false;
  const [a, b] = host.split('.').map(Number) as [number, number];
  if (a === 10) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  return false;
}

function isTailscale(host: string): boolean {
  if (!isIPv4(host)) return false;
  const [a, b] = host.split('.').map(Number) as [number, number];
  return a === 100 && b >= 64 && b <= 127;
}

/** Classifies an IPv4 literal as LAN, Tailscale/CGNAT, or neither. */
export function classifyAddress(host: string): AddressKind | null {
  if (isLan(host)) return 'lan';
  if (isTailscale(host)) return 'ts';
  return null;
}

function invalidPort(value: number | null): boolean {
  // Canonical digits only: `0`, `70000` and any non-integer are unusable.
  return value === null || !Number.isInteger(value) || value < 1 || value > 65535;
}

/** The canonical param order (and address order) is deterministic. */
export function formatPairingUri(payload: PairingPayload): string {
  const code = normalizeTicket(payload.code);
  if (code === null) {
    throw new Error(`pairing code is not a valid ticket: ${payload.code}`);
  }

  const params = [`v=${PAIRING_PROTOCOL_VERSION}`, `code=${code}`];

  if (payload.addresses.length === 0) {
    if (payload.viewerPort !== null) {
      throw new Error('pairing port requires at least one address');
    }
    return `pidroid://pair?${params.join('&')}`;
  }

  if (invalidPort(payload.viewerPort)) {
    throw new Error(`pairing port must be between 1 and 65535: ${String(payload.viewerPort)}`);
  }
  params.push(`port=${payload.viewerPort}`);

  const addresses = [...payload.addresses].sort(compareAddresses);
  for (const address of addresses) {
    if (classifyAddress(address.host) !== address.kind) {
      throw new Error(
        `address ${address.host} does not classify as ${address.kind}`,
      );
    }
    params.push(`${address.kind}=${address.host}`);
  }
  return `pidroid://pair?${params.join('&')}`;
}

/** Order-independent canonical ordering: LAN before TS, then by host. */
function compareAddresses(a: PairingAddress, b: PairingAddress): number {
  if (a.kind !== b.kind) return a.kind === 'lan' ? -1 : 1;
  return a.host < b.host ? -1 : a.host > b.host ? 1 : 0;
}

/** Parses a port param: canonical decimal digits, 1..65535. */
function parsePort(raw: string | null): number | null {
  if (raw === null || !/^[1-9][0-9]{0,4}$/.test(raw)) return null;
  const port = Number(raw);
  return port >= 1 && port <= 65535 ? port : null;
}

export function parsePairingUri(raw: string): PairingParseResult {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return { ok: false, error: 'not-a-pairing-uri' };
  }
  if (url.protocol !== 'pidroid:' || url.hostname !== 'pair') {
    return { ok: false, error: 'not-a-pairing-uri' };
  }

  const versions = url.searchParams.getAll('v');
  if (versions.length !== 1 || versions[0] !== String(PAIRING_PROTOCOL_VERSION)) {
    return { ok: false, error: 'unsupported-version' };
  }

  const code = normalizeTicket(url.searchParams.get('code'));
  if (code === null) return { ok: false, error: 'invalid-pairing-uri' };

  const lan = url.searchParams.getAll('lan');
  const ts = url.searchParams.getAll('ts');
  const addresses: PairingAddress[] = [];
  for (const host of lan) {
    if (classifyAddress(host) !== 'lan') return { ok: false, error: 'invalid-pairing-uri' };
    addresses.push({ kind: 'lan', host });
  }
  for (const host of ts) {
    if (classifyAddress(host) !== 'ts') return { ok: false, error: 'invalid-pairing-uri' };
    addresses.push({ kind: 'ts', host });
  }
  addresses.sort(compareAddresses);

  if (addresses.length === 0) {
    if (url.searchParams.has('port')) return { ok: false, error: 'invalid-pairing-uri' };
    return { ok: true, pairing: { code, viewerPort: null, addresses } };
  }

  const viewerPort = parsePort(url.searchParams.get('port'));
  if (viewerPort === null) return { ok: false, error: 'invalid-pairing-uri' };
  return { ok: true, pairing: { code, viewerPort, addresses } };
}
