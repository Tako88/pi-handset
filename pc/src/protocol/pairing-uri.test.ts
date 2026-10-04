// Pure tests for the `pidroid://pair` payload grammar. No I/O, no sockets.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  classifyAddress,
  formatPairingUri,
  parsePairingUri,
} from './pairing-uri.ts';

test('classifyAddress accepts every RFC1918 block at both edges', () => {
  for (const host of [
    '10.0.0.0',
    '10.255.255.255',
    '172.16.0.0',
    '172.31.255.255',
    '192.168.0.0',
    '192.168.255.255',
  ]) {
    assert.equal(classifyAddress(host), 'lan', host);
  }
});

test('classifyAddress accepts every 100.64/10 edge and rejects one past each', () => {
  assert.equal(classifyAddress('100.64.0.0'), 'ts');
  assert.equal(classifyAddress('100.127.255.255'), 'ts');
  assert.equal(classifyAddress('100.63.255.255'), null);
  assert.equal(classifyAddress('100.128.0.0'), null);
});

test('classifyAddress rejects one past every RFC1918 edge', () => {
  for (const host of [
    '9.255.255.255',
    '11.0.0.0',
    '172.15.255.255',
    '172.32.0.0',
    '192.167.0.1',
    '192.169.0.1',
  ]) {
    assert.equal(classifyAddress(host), null, host);
  }
});

test('classifyAddress returns null for non-LAN addresses and malformed input', () => {
  for (const host of [
    '127.0.0.1',
    '169.254.1.1',
    '8.8.8.8',
    '2001:db8::1',
    'not-an-ip',
    '',
  ]) {
    assert.equal(classifyAddress(host), null, host);
  }
});

test('formatPairingUri emits the canonical mixed LAN+TS string', () => {
  const uri = formatPairingUri({
    code: 'ABCD-2345',
    viewerPort: 8787,
    addresses: [
      { kind: 'ts', host: '100.64.1.2' },
      { kind: 'lan', host: '192.168.1.10' },
      { kind: 'lan', host: '10.0.0.5' },
    ],
  });
  assert.equal(
    uri,
    'pidroid://pair?v=1&code=ABCD2345&port=8787&lan=10.0.0.5&lan=192.168.1.10&ts=100.64.1.2',
  );
});

test('formatPairingUri emits no port and no address params for an empty list', () => {
  assert.equal(
    formatPairingUri({ code: 'ABCD2345', viewerPort: null, addresses: [] }),
    'pidroid://pair?v=1&code=ABCD2345',
  );
});

test('formatPairingUri refuses a port outside 1..65535', () => {
  const addresses = [{ kind: 'lan' as const, host: '192.168.1.10' }];
  for (const viewerPort of [0, 65536, -1]) {
    assert.throws(
      () => formatPairingUri({ code: 'ABCD2345', viewerPort, addresses }),
      /port/i,
    );
  }
});

test('formatPairingUri refuses an address whose value does not classify to its kind', () => {
  assert.throws(
    () =>
      formatPairingUri({
        code: 'ABCD2345',
        viewerPort: 8787,
        addresses: [{ kind: 'lan', host: '8.8.8.8' }],
      }),
    /classif|lan/i,
  );
});

test('parsePairingUri rejects a URI that is not pidroid://pair', () => {
  for (const raw of [
    'https://example.com/?v=1&code=ABCD2345',
    'pidroid://other?v=1&code=ABCD2345',
    'not a uri at all',
  ]) {
    assert.deepEqual(parsePairingUri(raw), {
      ok: false,
      error: 'not-a-pairing-uri',
    });
  }
});

test('parsePairingUri reports a missing or future v as unsupported-version', () => {
  for (const raw of [
    'pidroid://pair?code=ABCD2345',
    'pidroid://pair?v=2&code=ABCD2345',
  ]) {
    assert.deepEqual(parsePairingUri(raw), {
      ok: false,
      error: 'unsupported-version',
    });
  }
});

test('parsePairingUri normalizes a dashed code and ignores unknown params', () => {
  assert.deepEqual(
    parsePairingUri(
      'pidroid://pair?v=1&code=abcd-2345&port=8787&lan=10.0.0.5&LAN=5.5.5.5&lan2=1.2.3.4',
    ),
    {
      ok: true,
      pairing: {
        code: 'ABCD2345',
        viewerPort: 8787,
        addresses: [{ kind: 'lan', host: '10.0.0.5' }],
      },
    },
  );
});
