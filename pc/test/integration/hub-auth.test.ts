// authentication, capability gating and connection close.
// Split from the hub test file; test blocks are byte-exact (see .pi/plans/pc-test-split).

import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { WebSocket } from 'ws';
import { CLOSE_CAPABILITY, CLOSE_PROTOCOL, CLOSE_RATE_LIMITED } from '../../src/hub/hub.ts';
import { createTicketStore } from '../../src/hub/pairing.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

import { TOKEN, cleanup, startHub, barrier, closed, connect, helloTokened, helloViewer } from '../support/hub-harness.ts';

afterEach(cleanup);

test('the hub binds an ephemeral agent port and a viewer port and publishes both', async () => {
  const hub = await startHub();

  assert.ok(Number.isSafeInteger(hub.agentPort) && hub.agentPort > 0);
  assert.ok(hub.agentPort <= 65535);
  assert.ok(Number.isSafeInteger(hub.viewerPort) && hub.viewerPort > 0);
  assert.ok(hub.viewerPort <= 65535);
  assert.notEqual(hub.agentPort, hub.viewerPort);
});

test('a wrong token is never processed and closes the connection at the attempt cap', async () => {
  const hub = await startHub({ maxAuthAttempts: 3, authCloseDelayMs: 10 });
  const viewer = await connect(hub.viewerPort);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: 'b'.repeat(64) });
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: 'b'.repeat(64) });
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: 'b'.repeat(64) });

  const { code } = await closed(viewer);
  assert.equal(code, CLOSE_RATE_LIMITED);
});

test('an unauthenticated connection sending a non-hello is closed as a protocol violation', async () => {
  const hub = await startHub({ maxAuthAttempts: 3, authCloseDelayMs: 10 });
  const viewer = await connect(hub.viewerPort);

  // A stale-token bridge must not sit "connected" forever while the hub
  // silently drops its register/events. Any non-`hello` before authentication
  // is a protocol violation and closes the connection immediately.
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: 'b'.repeat(64) });
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });

  const { code } = await closed(viewer);
  assert.equal(code, CLOSE_PROTOCOL);
});

test('a connection that never authenticates is closed at the auth deadline', async () => {
  const hub = await startHub({ authDeadlineMs: 50 });
  const viewer = await connect(hub.viewerPort);

  const { code } = await closed(viewer);
  assert.equal(code, CLOSE_RATE_LIMITED);
});

test('a connection that authenticates before the deadline stays connected past it', async () => {
  const hub = await startHub({ authDeadlineMs: 100 });
  const viewer = await connect(hub.viewerPort);
  await helloTokened(viewer);

  await new Promise((resolve) => setTimeout(resolve, 250));
  assert.equal(viewer.ws.readyState, WebSocket.OPEN);
});

test('an unauthenticated viewer beyond the cap is closed immediately, leaves the viewer set, and the cap releases on auth', async () => {
  const hub = await startHub({ maxUnauthenticatedViewers: 1, authDeadlineMs: 5000 });
  const first = await connect(hub.viewerPort);
  const second = await connect(hub.viewerPort);

  assert.equal((await closed(second)).code, CLOSE_RATE_LIMITED);
  assert.equal(first.ws.readyState, WebSocket.OPEN);

  // `first` authenticating frees its slot; a leaked refused `second` would
  // keep the unauthenticated count at 1 and make this third dial be refused.
  await helloViewer(first);

  const third = await connect(hub.viewerPort);
  await helloViewer(third);
});

test('a valid ticket pairs once and the hub replies with paired carrying the token', async () => {
  const tickets = createTicketStore();
  const ticket = tickets.issue();
  const hub = await startHub({ tickets, maxAuthAttempts: 2, authCloseDelayMs: 10 });

  const first = await connect(hub.viewerPort);
  first.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', ticket });
  const paired = await first.next();
  assert.equal(paired.type, 'paired');
  assert.equal(paired.token, TOKEN);

  // The ticket is single-use: a second connection cannot redeem it.
  const second = await connect(hub.viewerPort);
  second.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', ticket });
  assert.equal(await second.tryNext(150), undefined, 'a spent ticket must not pair again');
  second.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', ticket });
  assert.equal((await closed(second)).code, CLOSE_RATE_LIMITED);
});

test('with a valid token, a viewer sending register is closed as a capability violation', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });

  const { code } = await closed(viewer);
  assert.equal(code, CLOSE_CAPABILITY);
});

test('with a valid token, an agent sending command is closed as a capability violation', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });
  await barrier(agent);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c1',
    sessionId: 's1',
    name: 'prompt',
    args: { text: 'hi' },
  });

  const { code } = await closed(agent);
  assert.equal(code, CLOSE_CAPABILITY);
});

test('with a valid token, a viewer sending sessions is closed as a capability violation', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);
  await helloTokened(viewer);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'sessions', sessions: [] });

  const { code } = await closed(viewer);
  assert.equal(
    code,
    CLOSE_CAPABILITY,
    'sessions is hub→viewer only; a viewer may not publish a registry',
  );
});

test('with a valid token, an agent sending sessions is closed as a capability violation', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  await helloTokened(agent);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'sessions', sessions: [] });

  const { code } = await closed(agent);
  assert.equal(
    code,
    CLOSE_CAPABILITY,
    'sessions is hub→viewer only; an agent may not publish a registry',
  );
});

test('a valid token authenticates with only the session list as an unsolicited reply', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });
  // `hello` has exactly one unsolicited reply now: the session list. Anchor it,
  // then the next message must be the reply to a *later* request.
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 'ghost' });

  const first = await viewer.nextSessions(2000);
  assert.equal(first.type, 'sessions');
  assert.deepEqual(first.sessions, []);
  const gone = await viewer.next(2000);
  assert.equal(gone.type, 'session-gone');
  assert.equal(gone.sessionId, 'ghost');
});

test('a frame larger than maxPayload is rejected without taking the hub down', async () => {
  const hub = await startHub({ maxPayload: 8192 });
  const oversized = await connect(hub.viewerPort);

  oversized.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'hello',
    token: 'a'.repeat(20_000),
  });
  const { code } = await closed(oversized, 3000);
  assert.equal(code, 1009, 'a frame over maxPayload closes with 1009 (message too big)');

  // The hub is still serving: a fresh connection authenticates normally.
  const fresh = await connect(hub.viewerPort);
  await helloViewer(fresh);
  fresh.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 'ghost' });
  assert.equal((await fresh.next(2000)).type, 'session-gone');
});

test('a viewer sending agent-settled is closed as a capability violation', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'agent-settled',
    sessionId: 's1',
    label: 'work',
    text: 'Done.',
    truncated: false,
  });

  const { code } = await closed(viewer);
  assert.equal(code, CLOSE_CAPABILITY);
});
