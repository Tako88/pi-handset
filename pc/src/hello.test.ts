import assert from 'node:assert/strict';
import { test } from 'node:test';

// The specifier is deliberately `.ts` — probing whether Node's native type
// stripping resolves it (plan Open Question 3). Before `src/hello.ts` exists,
// this must fail with a *missing-module* error, not a strip or loader error.
import { answer } from './hello.ts';

test('the canary answers 42', () => {
  assert.equal(answer(), 42);
});
