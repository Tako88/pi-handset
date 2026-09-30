import assert from 'node:assert/strict';
import { test } from 'node:test';

// Deliberately `.ts`, and deliberately written before `./pairing.ts` exists:
// the red run must fail with an unresolved import, not a loader error.
import {
  TICKET_ALPHABET,
  TICKET_TTL_MS,
  createTicketStore,
  normalizeTicket,
} from './pairing.ts';
import type { RedeemResult } from './pairing.ts';

/** A deterministic byte source: the exact bytes the test hands back. */
function fixedRandom(...bytes: number[]): (size: number) => Uint8Array {
  return (size: number): Uint8Array => {
    assert.equal(size, bytes.length, 'randomBytes called with an unexpected size');
    return Uint8Array.from(bytes);
  };
}

/** The one ticket `fixedRandom(0..7)` must produce, plus a controllable clock. */
function setup(): { store: ReturnType<typeof createTicketStore>; advance: (ms: number) => void } {
  let now = 0;
  const store = createTicketStore({
    now: () => now,
    randomBytes: fixedRandom(0, 1, 2, 3, 4, 5, 6, 7),
  });
  return { store, advance: (ms: number) => void (now += ms) };
}

test('the ticket alphabet has exactly 32 distinct characters', () => {
  assert.equal(TICKET_ALPHABET.length, 32);
  assert.equal(new Set(TICKET_ALPHABET).size, 32);
});

test('the ticket alphabet excludes the ambiguous I, L, O and U', () => {
  for (const ambiguous of ['I', 'L', 'O', 'U']) {
    assert.equal(
      TICKET_ALPHABET.includes(ambiguous),
      false,
      `${ambiguous} must not be in the alphabet`,
    );
  }
});

test('issue returns 8 alphabet characters displayed as XXXX-XXXX', () => {
  const { store } = setup();
  assert.equal(store.issue(), '0123-4567');
});

test('generated tickets contain only in-alphabet characters', () => {
  // Real randomness, no injected source: the point is to exercise 200 distinct
  // tickets, not to assert a specific value.
  const store = createTicketStore();
  for (let i = 0; i < 200; i++) {
    const ticket = store.issue();
    assert.match(ticket, /^[0-9A-Z]{4}-[0-9A-Z]{4}$/);
    for (const ch of ticket.replace('-', '')) {
      assert.ok(TICKET_ALPHABET.includes(ch), `unexpected character ${ch} in ${ticket}`);
    }
  }
});

test('a byte source returning fewer than 8 bytes makes issue throw', () => {
  const store = createTicketStore({ randomBytes: () => Uint8Array.from([0, 1, 2]) });
  assert.throws(() => store.issue(), /at least 8 bytes/);
});

test('normalization uppercases and strips dashes', () => {
  assert.equal(normalizeTicket('abcd-2345'), 'ABCD2345');
});

test('a dashed and a spaced ticket normalize alike', () => {
  assert.equal(normalizeTicket('xxxx-xxxx'), 'XXXXXXXX');
  assert.equal(normalizeTicket('XXXX XXXX'), 'XXXXXXXX');
});

test('normalization returns null for non-string input rather than throwing', () => {
  for (const input of [null, 42, {}, []]) {
    assert.equal(normalizeTicket(input), null, `${JSON.stringify(input)} must be rejected`);
  }
});

test('normalization rejects ambiguous characters rather than mapping them', () => {
  for (const bad of ['IIIIIIII', 'LLLLLLLL', 'OOOOOOOO', 'UUUUUUUU']) {
    assert.equal(normalizeTicket(bad), null, `${bad} must be rejected`);
  }
});

test('normalization rejects punctuation', () => {
  assert.equal(normalizeTicket('ABCD!234'), null);
});

test('normalization rejects a wrong-length ticket', () => {
  assert.equal(normalizeTicket('ABC-234'), null);
});

test('a freshly issued ticket redeems successfully', () => {
  const { store } = setup();
  const ticket = store.issue();
  assert.deepEqual(store.redeem(ticket), { ok: true });
});

test('a ticket may be redeemed without its dash', () => {
  const { store } = setup();
  store.issue();
  assert.deepEqual(store.redeem('01234567'), { ok: true });
});

test('a well-formed but unknown ticket is rejected as unknown', () => {
  const { store } = setup();
  store.issue();
  assert.deepEqual(store.redeem('ZZZZZZZZ'), {
    ok: false,
    code: 'unknown',
    error: 'no such ticket',
  });
});

test('a malformed candidate is rejected as malformed', () => {
  const { store } = setup();
  store.issue();
  const result = store.redeem('not a ticket!');
  assert.equal(result.ok, false);
  if (!result.ok) assert.equal(result.code, 'malformed');
});

test('a ticket is still valid one millisecond before its 5 minute TTL', () => {
  const { store, advance } = setup();
  const ticket = store.issue();
  advance(TICKET_TTL_MS - 1);
  assert.deepEqual(store.redeem(ticket), { ok: true });
});

test('an expired ticket is rejected and discarded', () => {
  const { store, advance } = setup();
  const ticket = store.issue();
  advance(TICKET_TTL_MS);
  const expired = store.redeem(ticket);
  assert.equal(expired.ok, false);
  if (!expired.ok) assert.equal(expired.code, 'expired');
  // discarded: the same ticket is now simply unknown
  const again = store.redeem(ticket);
  assert.equal(again.ok, false);
  if (!again.ok) assert.equal(again.code, 'unknown');
});

test('a burned ticket past its TTL reports expired once, then unknown', () => {
  const { store, advance } = setup();
  const ticket = store.issue();
  for (let attempt = 1; attempt <= 5; attempt++) {
    const result = store.redeem('ZZZZZZZZ');
    assert.equal(result.ok, false);
  }
  advance(TICKET_TTL_MS);
  const expired = store.redeem(ticket);
  assert.equal(expired.ok, false);
  if (!expired.ok) assert.equal(expired.code, 'expired');
  const again = store.redeem(ticket);
  assert.equal(again.ok, false);
  if (!again.ok) assert.equal(again.code, 'unknown');
});

test('the 5th failed attempt burns the ticket so the 6th also fails', () => {
  const { store } = setup();
  const ticket = store.issue();
  for (let attempt = 1; attempt <= 4; attempt++) {
    const result = store.redeem('ZZZZZZZZ');
    assert.equal(result.ok, false);
    if (!result.ok) assert.equal(result.code, 'unknown');
  }
  const fifth = store.redeem('ZZZZZZZZ');
  assert.equal(fifth.ok, false);
  if (!fifth.ok) assert.equal(fifth.code, 'unknown');
  const sixth = store.redeem(ticket);
  assert.equal(sixth.ok, false);
  if (!sixth.ok) assert.equal(sixth.code, 'burned');
});

test('a successful redemption does not count toward the failure cap', () => {
  const { store } = setup();
  const ticket = store.issue();
  for (let attempt = 1; attempt <= 4; attempt++) {
    const result = store.redeem('ZZZZZZZZ');
    assert.equal(result.ok, false);
    if (!result.ok) assert.equal(result.code, 'unknown');
  }
  assert.deepEqual(store.redeem(ticket), { ok: true });
});

test('one ticket redeemed twice yields exactly one success', async () => {
  // The Promise.all shape guards a future async refactor, but `redeem` is
  // synchronous here, so this proves single-use, NOT interleaving.
  const { store } = setup();
  const ticket = store.issue();
  const results: RedeemResult[] = await Promise.all([
    store.redeem(ticket),
    store.redeem(ticket),
  ]);
  assert.equal(results.filter((result) => result.ok).length, 1);
});
