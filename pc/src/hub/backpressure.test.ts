import assert from 'node:assert/strict';
import { test } from 'node:test';

// Deliberately written before `./backpressure.ts` exists: red must be an
// unresolved import.
import { ByteBudget } from './backpressure.ts';

test('a message that fits inside the cap is admitted and accounted', () => {
  const budget = new ByteBudget(100);

  assert.equal(budget.admit(60), true);
  assert.equal(budget.queued, 60);
});

test('a message that would exceed the cap is dropped whole', () => {
  const budget = new ByteBudget(100);
  assert.equal(budget.admit(60), true);

  assert.equal(budget.admit(60), false, 'the second message is dropped, not partially sent');
  assert.equal(budget.queued, 60, 'a dropped message is not accounted');
});

test('a message exactly equal to the cap is admitted', () => {
  const budget = new ByteBudget(100);

  assert.equal(budget.admit(100), true);
});

test('draining releases exactly the bytes written', () => {
  const budget = new ByteBudget(100);
  budget.admit(60);

  budget.drain(60);

  assert.equal(budget.queued, 0);
  assert.equal(budget.admit(100), true);
});

test('draining below zero is clamped', () => {
  const budget = new ByteBudget(100);

  budget.drain(50);

  assert.equal(budget.queued, 0);
});
