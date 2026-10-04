/**
 * Which addresses a phone on the same LAN or Tailscale network could dial.
 *
 * Pure over an injected interface map, so it tests without touching the real
 * machine. `classifyAddress` (from the shared pairing-uri grammar) is the one
 * classifier; a `lan`/`ts` value is kept only when it classifies to its kind,
 * and the emitter app would otherwise label a public IP as "Home network".
 *
 * Dropped: loopback and link-local (the classifier already returns null for
 * them), non-IPv4, and container/bridge interfaces by name — a docker0 or
 * virbr0 address is reachable from the host but not from the user's phone.
 */

import type { NetworkInterfaceInfo } from 'node:os';

import { classifyAddress } from '../protocol/pairing-uri.ts';
import type { PairingAddress } from '../protocol/pairing-uri.ts';

const CONTAINER_INTERFACE = /^(docker|veth|br-|virbr)/;

function compare(a: PairingAddress, b: PairingAddress): number {
  if (a.kind !== b.kind) return a.kind === 'lan' ? -1 : 1;
  return a.host < b.host ? -1 : a.host > b.host ? 1 : 0;
}

export function enumerateAddresses(
  interfaces: NodeJS.Dict<NetworkInterfaceInfo[]>,
): PairingAddress[] {
  const found: PairingAddress[] = [];
  for (const [name, entries] of Object.entries(interfaces)) {
    if (CONTAINER_INTERFACE.test(name)) continue;
    for (const entry of entries ?? []) {
      if (entry.internal || entry.family !== 'IPv4') continue;
      const kind = classifyAddress(entry.address);
      if (kind !== null) found.push({ kind, host: entry.address });
    }
  }
  return found.sort(compare);
}
