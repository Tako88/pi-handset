import assert from 'node:assert/strict';
import { test } from 'node:test';

// Smoke test so the integration glob can never zero-match silently — a
// zero-match run would look like a green suite that tests nothing.
test('the integration suite runs at all', () => {
  assert.equal(typeof process.version, 'string');
});
