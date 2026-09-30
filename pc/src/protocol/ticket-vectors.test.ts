// The shared ticket-normalization vectors, asserted against the REAL
// `normalizeTicket` from `pairing.ts` (never a re-implementation), so the
// vectors and the production normalizer cannot drift apart.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { TICKET_ALPHABET, normalizeTicket } from '../hub/pairing.ts';

interface TicketVector {
  name: string;
  input: unknown;
  accept: boolean;
  normalized?: string;
}

interface VectorFile {
  alphabet: string;
  length: number;
  vectors: TicketVector[];
}

const vectorsPath = fileURLToPath(
  new URL('../../../protocol/fixtures/tickets/vectors.json', import.meta.url),
);
const file = JSON.parse(readFileSync(vectorsPath, 'utf8')) as VectorFile;

test('the vector file pins the same alphabet and length pairing.ts uses', () => {
  assert.equal(file.alphabet, TICKET_ALPHABET);
  assert.equal(file.length, 8);
});

test('every vector normalizes exactly as pairing.ts does', () => {
  assert.ok(file.vectors.length > 0, 'the vector file must not be empty');
  for (const vector of file.vectors) {
    const result = normalizeTicket(vector.input);
    if (vector.accept) {
      assert.equal(
        result,
        vector.normalized,
        `${vector.name}: expected ${String(vector.normalized)}, got ${String(result)}`,
      );
    } else {
      assert.equal(result, null, `${vector.name}: expected rejection, got ${String(result)}`);
    }
  }
});
