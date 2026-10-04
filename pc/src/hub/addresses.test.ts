// Pure tests for phone-reachable address enumeration. No real interfaces.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { NetworkInterfaceInfo } from 'node:os';

import { enumerateAddresses } from './addresses.ts';

function ipv4(
  address: string,
  extra: Partial<NetworkInterfaceInfo> = {},
): NetworkInterfaceInfo {
  return {
    address,
    netmask: '255.255.255.0',
    family: 'IPv4',
    mac: '00:00:00:00:00:00',
    internal: false,
    cidr: `${address}/24`,
    ...extra,
  } as NetworkInterfaceInfo;
}

test('drops a loopback entry', () => {
  assert.deepEqual(
    enumerateAddresses({ lo: [ipv4('127.0.0.1', { internal: true })] }),
    [],
  );
});

test('drops a link-local entry', () => {
  assert.deepEqual(enumerateAddresses({ eth0: [ipv4('169.254.10.1')] }), []);
});

test('drops container and bridge interfaces by name', () => {
  assert.deepEqual(
    enumerateAddresses({
      docker0: [ipv4('172.17.0.1')],
      vethabc123: [ipv4('10.1.2.3')],
      'br-abc': [ipv4('192.168.99.1')],
      virbr0: [ipv4('192.168.122.1')],
    }),
    [],
  );
});

test('keeps a tailscale0 100.64/10 address as ts', () => {
  assert.deepEqual(enumerateAddresses({ tailscale0: [ipv4('100.64.1.2')] }), [
    { kind: 'ts', host: '100.64.1.2' },
  ]);
});

test('keeps eth0/wlan0 RFC1918 addresses as lan', () => {
  assert.deepEqual(
    enumerateAddresses({
      eth0: [ipv4('192.168.1.10')],
      wlan0: [ipv4('10.0.0.5')],
    }),
    [
      { kind: 'lan', host: '10.0.0.5' },
      { kind: 'lan', host: '192.168.1.10' },
    ],
  );
});

test('ignores a non-IPv4 entry', () => {
  assert.deepEqual(
    enumerateAddresses({
      eth0: [
        {
          address: '2001:db8::1',
          netmask: 'ffff:ffff:ffff:ffff::',
          family: 'IPv6',
          mac: '00:00:00:00:00:00',
          internal: false,
          cidr: '2001:db8::1/64',
          scopeid: 0,
        },
      ],
    }),
    [],
  );
});

test('returns a deterministic kind-then-host sorted list', () => {
  const result = enumerateAddresses({
    a0: [ipv4('100.64.1.2')],
    a1: [ipv4('192.168.1.10')],
    a2: [ipv4('10.0.0.5')],
    a3: [ipv4('100.64.0.1')],
  });
  assert.deepEqual(result, [
    { kind: 'lan', host: '10.0.0.5' },
    { kind: 'lan', host: '192.168.1.10' },
    { kind: 'ts', host: '100.64.0.1' },
    { kind: 'ts', host: '100.64.1.2' },
  ]);
});

test('returns [] for an empty interface map', () => {
  assert.deepEqual(enumerateAddresses({}), []);
});
