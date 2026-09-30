import assert from 'node:assert/strict';
import { test } from 'node:test';

// Deliberately written before `./serve.ts` exists: red must be an unresolved import.
import { pairingAnnouncement, pairingCodeNotice, parseArgs } from './serve.ts';

test('parseArgs defaults to port 8787, LAN on, no take-over', () => {
  assert.deepEqual(parseArgs([]), { port: 8787, lan: true, takeOver: false });
});

test('parseArgs reads --port', () => {
  assert.equal(parseArgs(['--port', '9000']).port, 9000);
});

test('parseArgs rejects a non-integer --port', () => {
  assert.throws(() => parseArgs(['--port', 'abc']), /port/i);
  assert.throws(() => parseArgs(['--port', '8.5']), /port/i);
});

test('parseArgs accepts digit-only ports and rejects every non-digit form', () => {
  for (const bad of ['0x10', '1e3', '9000.0', ' 9000', '9000 ', '+9000', '']) {
    assert.throws(() => parseArgs(['--port', bad]), /port/i, `--port ${bad}`);
  }
});

test('parseArgs rejects --port=9000 rather than silently ignoring it', () => {
  assert.throws(() => parseArgs(['--port=9000']), /--port=9000/);
});

test('parseArgs rejects a --port out of range', () => {
  assert.throws(() => parseArgs(['--port', '0']), /port/i);
  assert.throws(() => parseArgs(['--port', '65536']), /port/i);
  assert.throws(() => parseArgs(['--port', '-1']), /port/i);
});

test('parseArgs rejects a --port with no value', () => {
  assert.throws(() => parseArgs(['--port']), /port/i);
});

test('parseArgs reads --no-lan', () => {
  assert.equal(parseArgs(['--no-lan']).lan, false);
});

test('parseArgs reads --take-over', () => {
  assert.equal(parseArgs(['--take-over']).takeOver, true);
});

test('parseArgs rejects an unknown flag instead of ignoring it', () => {
  assert.throws(() => parseArgs(['--wat']), /--wat/);
});

test('parseArgs combines flags', () => {
  assert.deepEqual(parseArgs(['--port', '9123', '--no-lan', '--take-over']), {
    port: 9123,
    lan: false,
    takeOver: true,
  });
});

test('a post-shutdown SIGUSR1 mints no pairing code', () => {
  let issued = 0;
  const announcement = pairingAnnouncement(true, () => {
    issued += 1;
    return 'ABCD-EFGH';
  });
  assert.equal(announcement, null);
  assert.equal(issued, 0, 'a shutting-down hub must not mint a ticket');
});

test('a SIGUSR1 while running prints a redeemable code', () => {
  const announcement = pairingAnnouncement(false, () => 'ABCD-EFGH');
  assert.equal(announcement, pairingCodeNotice('ABCD-EFGH'));
});
