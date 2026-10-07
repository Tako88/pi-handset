// The shared `pihandset://pair` vectors, asserted against the REAL format/parse
// code (never a re-implementation), so the fixture and `pairing-uri.ts` cannot
// drift apart. #36 drives the same file from the Dart port.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { formatPairingUri, parsePairingUri } from './pairing-uri.ts';
import type { PairingPayload } from './pairing-uri.ts';

interface Vector {
  name: string;
  kind: 'canonical' | 'accepted' | 'rejected';
  uri: string;
  pairing?: PairingPayload;
  error?: string;
}

interface VectorFile {
  version: number;
  vectors: Vector[];
}

const vectorsPath = fileURLToPath(
  new URL('../../../protocol/fixtures/pairing/vectors.json', import.meta.url),
);
const file = JSON.parse(readFileSync(vectorsPath, 'utf8')) as VectorFile;

test('the pairing vector file pins version 1 and is not empty', () => {
  assert.equal(file.version, 1);
  assert.ok(file.vectors.length > 0, 'the vector file must not be empty');
});

test('every canonical vector formats to exactly its uri and parses back', () => {
  const canonical = file.vectors.filter((vector) => vector.kind === 'canonical');
  assert.ok(canonical.length > 0);
  for (const vector of canonical) {
    const pairing = vector.pairing!;
    assert.equal(
      formatPairingUri(pairing),
      vector.uri,
      `${vector.name}: canonical emission drifted`,
    );
    assert.deepEqual(
      parsePairingUri(vector.uri),
      { ok: true, pairing },
      `${vector.name}: parse drifted`,
    );
  }
});

test('every accepted-only vector parses to its pairing', () => {
  const accepted = file.vectors.filter((vector) => vector.kind === 'accepted');
  assert.ok(accepted.length > 0);
  for (const vector of accepted) {
    assert.deepEqual(
      parsePairingUri(vector.uri),
      { ok: true, pairing: vector.pairing },
      `${vector.name}: accepted parse drifted`,
    );
  }
});

test('every rejected vector fails with its named error', () => {
  const rejected = file.vectors.filter((vector) => vector.kind === 'rejected');
  assert.ok(rejected.length > 0);
  for (const vector of rejected) {
    assert.deepEqual(
      parsePairingUri(vector.uri),
      { ok: false, error: vector.error },
      `${vector.name}: rejection drifted`,
    );
  }
});
