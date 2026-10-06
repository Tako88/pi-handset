/**
 * Single-use pairing tickets.
 *
 * A ticket is 8 characters from a 32-character Crockford-style alphabet
 * (2^40 combinations), displayed as `XXXX-XXXX`. It is single-use, expires
 * after 5 minutes, and is burned by 5 failed redemption attempts.
 *
 * Pure-ish: no I/O, no timers. Time and randomness are injected so the tests
 * can advance a clock and supply bytes instead of sleeping or racing.
 */

import {
  randomBytes as nodeRandomBytes,
  timingSafeEqual,
} from 'node:crypto';

/** Digits plus A–Z minus the ambiguous `I`, `L`, `O`, `U`. Exactly 32 characters. */
export const TICKET_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/** Ticket lifetime. Exported so callers and tests name the value, not the number. */
export const TICKET_TTL_MS = 5 * 60_000;

const TICKET_LENGTH = 8;
const MAX_FAILED_ATTEMPTS = 5;

/** Machine-readable failure reasons, stable enough for M5 to map and M7 to port. */
export type RedeemErrorCode = 'unknown' | 'malformed' | 'expired' | 'burned';

export type RedeemResult =
  | { ok: true }
  | { ok: false; code: RedeemErrorCode; error: string };

export interface TicketStoreDeps {
  /** Clock in epoch milliseconds. Defaults to `Date.now`. */
  now?: () => number;
  /** Byte source. Defaults to `crypto.randomBytes`. */
  randomBytes?: (size: number) => Uint8Array;
}

/**
 * Uppercases, strips dashes and whitespace, then **rejects** (never maps) any
 * character outside the alphabet. Returns the 8-character form, or null.
 * Exported because M7's Dart port must mirror it against shared fixtures.
 */
export function normalizeTicket(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const compact = raw.replace(/[-\s]/g, '').toUpperCase();
  if (compact.length !== TICKET_LENGTH) return null;
  for (const ch of compact) {
    if (!TICKET_ALPHABET.includes(ch)) return null;
  }
  return compact;
}

function fail(code: RedeemErrorCode, error: string): RedeemResult {
  return { ok: false, code, error };
}

/**
 * One ticket is outstanding at a time: `pair` prints a ticket and the phone
 * redeems it, so a failed attempt has exactly one ticket to charge and the
 * cap is unambiguously per-ticket. Issuing again replaces the previous ticket.
 */
export function createTicketStore(deps: TicketStoreDeps = {}) {
  const now = deps.now ?? (() => Date.now());
  const randomBytes = deps.randomBytes ?? nodeRandomBytes;

  let active: { value: string; expiresAt: number; failures: number; burned: boolean } | null =
    null;

  return {
    issue(): string {
      let value = '';
      const bytes = randomBytes(TICKET_LENGTH);
      if (bytes.length < TICKET_LENGTH) {
        throw new Error(
          `randomBytes returned fewer than ${TICKET_LENGTH} bytes: ` +
            `at least ${TICKET_LENGTH} bytes are required to mint a ticket`,
        );
      }
      // 256 is an exact multiple of 32, so masking a random byte is uniform.
      for (let i = 0; i < TICKET_LENGTH; i++) {
        value += TICKET_ALPHABET[bytes[i] & 31];
      }
      active = { value, expiresAt: now() + TICKET_TTL_MS, failures: 0, burned: false };
      return `${value.slice(0, 4)}-${value.slice(4)}`;
    },

    redeem(candidate: string): RedeemResult {
      const normalized = normalizeTicket(candidate);
      if (normalized === null) {
        return fail('malformed', 'ticket must be 8 characters from the alphabet');
      }
      const record = active;
      if (record === null) return fail('unknown', 'no such ticket');
      // Expiry is checked before burn: a burned ticket past its TTL must report
      // `expired` once (and be cleared) rather than `burned` forever.
      if (now() >= record.expiresAt) {
        active = null;
        return fail('expired', 'ticket expired');
      }
      if (record.burned) return fail('burned', 'ticket burned after too many failed attempts');

      // Compare-and-burn: no `await` between this comparison and the burn, so
      // under Node's single-threaded model two concurrent redemptions cannot
      // both win. Belt-and-braces: the 5-attempt cap already bounds guessing.
      // Normalization guarantees both sides are 8 in-alphabet characters, so
      // they are already equal-length for timingSafeEqual (which throws on
      // unequal-length buffers) - no digest is needed to equalize them.
      const matches = timingSafeEqual(
        Buffer.from(normalized, 'utf8'),
        Buffer.from(record.value, 'utf8'),
      );
      if (matches) {
        active = null;
        return { ok: true };
      }

      record.failures += 1;
      if (record.failures >= MAX_FAILED_ATTEMPTS) record.burned = true;
      return fail('unknown', 'no such ticket');
    },
  };
}

/** The ticket authority M5's hub holds; the concrete store shape stays private. */
export type TicketStore = ReturnType<typeof createTicketStore>;
