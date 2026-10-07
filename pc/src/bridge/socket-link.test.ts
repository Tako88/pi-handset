// The socket link's one piece of pure logic: what a transport error event
// actually says. It exists because a bare "socket error" line cannot tell a
// reset from a refused dial, and a CI-only flake once needed exactly that.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { describeSocketError } from './socket-link.ts';

test('a socket error event contributes the underlying error message', () => {
  assert.equal(describeSocketError({ error: new Error('read ECONNRESET') }), ': read ECONNRESET');
});

test('a socket error event contributes its own message when it carries no error', () => {
  assert.equal(describeSocketError({ message: 'connection refused' }), ': connection refused');
});

test('a socket error event with nothing to say contributes nothing', () => {
  for (const event of [{}, { message: '' }, { error: new Error('') }, null, undefined, 'boom', 7]) {
    assert.equal(describeSocketError(event), '', `unexpected detail for ${JSON.stringify(event)}`);
  }
});

test('the underlying error wins over a generic event message', () => {
  assert.equal(
    describeSocketError({ error: new Error('read ECONNRESET'), message: 'WebSocket error' }),
    ': read ECONNRESET',
  );
});
