// pending spawns.
// Split from the hub test file; test blocks are byte-exact.
//
// Preserved from the original hub test file:
//
// ---------------------------------------------------------------------------
// Pending spawns: the placeholder row and its failure delivery
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { createHub } from '../../src/hub/hub.ts';
import { createTicketStore } from '../../src/hub/pairing.ts';
import { createSpawner } from '../../src/hub/spawner.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

import { TOKEN, scratchHome, cleanup, startHub, makeFakeSpawner, barrier, recordFrames, connect, helloTokened, helloViewer } from '../support/hub-harness.ts';

afterEach(cleanup);

test('a start-session shows a pending row until the child registers', async () => {
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner });
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agent);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });
  assert.equal((await viewer.next(2000)).ok, true);

  // The ack lands before the row; the placeholder is a separate `sessions` push.
  const pendingPush = await viewer.nextSessions(2000);
  assert.deepEqual(pendingPush.sessions, []);
  assert.deepEqual(pendingPush.pending, [{ id: 'pending-1', label: 'New session' }]);

  // The child registers: the placeholder is replaced by the real session and the
  // `pending` key disappears.
  spawner.owned.add(4242);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    pid: 4242,
    name: 'app one',
  });
  const registered = await viewer.nextSessions(2000);
  assert.equal(registered.pending, undefined);
  assert.deepEqual(registered.sessions, [
    { sessionId: 's1', label: 'app one', agentState: 'idle', origin: 'app' },
  ]);
});

test('a registered child is not later failed as pending', async () => {
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner });
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agent);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });
  await viewer.next(2000);
  await viewer.nextSessions(2000); // the placeholder push

  spawner.owned.add(4242);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1', pid: 4242 });
  await barrier(agent);
  await viewer.nextSessions(2000); // the register push clears the placeholder

  // The child dies later. Its placeholder is gone, so nothing matches: no
  // failure frame, and no redundant push.
  spawner.fireExit(4242, 'exit');
  await barrier(viewer);

  assert.equal(await viewer.tryNext(150), undefined, 'no spawn-failed after register');
  assert.equal(await viewer.tryNextSessions(150), undefined, 'no extra push after register');
});

test('a pending spawn that hits the deadline is failed', async () => {
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  const frames = recordFrames(viewer);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });
  await viewer.next(2000); // the ack
  await viewer.nextSessions(2000); // the placeholder push
  frames.length = 0;

  spawner.fireExit(4242, 'deadline');

  const failure = await viewer.next(2000);
  const after = await viewer.nextSessions(2000);
  assert.deepEqual(failure, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'spawn-failed',
    id: 'pending-1',
    error: 'the session did not start in time',
  });
  assert.equal(after.pending, undefined, 'the failed placeholder must be gone');
  assert.deepEqual(
    frames.map((frame) => frame.type),
    ['spawn-failed', 'sessions'],
    'the failure must arrive before the pending-removing broadcast',
  );
});

test('a pending spawn whose child exits is failed', async () => {
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  const frames = recordFrames(viewer);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });
  await viewer.next(2000);
  await viewer.nextSessions(2000);
  frames.length = 0;

  spawner.fireExit(4242, 'exit');

  const failure = await viewer.next(2000);
  const after = await viewer.nextSessions(2000);
  assert.deepEqual(failure, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'spawn-failed',
    id: 'pending-1',
    error: 'the session exited before it started',
  });
  assert.equal(after.pending, undefined);
  assert.deepEqual(
    frames.map((frame) => frame.type),
    ['spawn-failed', 'sessions'],
    'the failure must arrive before the pending-removing broadcast',
  );
});

test('a real child that exits instantly is failed through the hub, placeholder first', async () => {
  // FM3's "the placeholder `.then` microtask beats the child's `exit` I/O"
  // ordering argument was only ever witnessed by `FakeSpawner.fireExit`, which
  // fires after the placeholder push by construction. This drives a REAL
  // spawner (the `sh -c 'exit 0'` shape S1 uses) through a REAL hub: the child
  // dies immediately, so the register-never-arrives path is exercised end to
  // end. If the ordering were wrong, the exit would be handled before the
  // placeholder existed and no `spawn-failed` would ever arrive.
  const spawner = createSpawner({
    command: 'sh',
    args: ['-c', 'exit 0'],
    tempRoot: scratchHome(),
    // Long enough that the deadline cannot be mistaken for the child's exit.
    registrationTimeoutMs: 60_000,
  });
  const hub = await startHub({ spawner });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  const frames = recordFrames(viewer);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });
  assert.equal((await viewer.next(2000)).ok, true, 'the start is acked');

  const pendingPush = await viewer.nextSessions(2000);
  assert.deepEqual(pendingPush.sessions, []);
  assert.deepEqual(pendingPush.pending, [{ id: 'pending-1', label: 'New session' }]);

  const failure = await viewer.next(2000);
  const after = await viewer.nextSessions(2000);
  assert.deepEqual(failure, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'spawn-failed',
    id: 'pending-1',
    error: 'the session exited before it started',
  });
  assert.equal(after.pending, undefined, 'the failed placeholder must be gone');
  assert.deepEqual(
    frames.map((frame) => frame.type),
    ['command-result', 'sessions', 'spawn-failed', 'sessions'],
    'the placeholder must precede the real exit, and the failure the removing push',
  );
});

test('a spawn-failed is delivered even when every budgeted frame is dropped', async () => {
  // `maxViewerBytes: 1` drops every budgeted frame (the auth push, the ack and
  // the placeholder push). Only the unbudgeted `send()` path can get through, so
  // this is a real witness that the failure is not sent under a budget.
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner, maxViewerBytes: 1 });
  const viewer = await connect(hub.viewerPort);
  await helloTokened(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });
  // Round-trip a ping so the hub has processed the start and created the
  // placeholder before the synthetic exit fires.
  await barrier(viewer);
  spawner.fireExit(4242, 'deadline');

  const failure = await viewer.next(2000);
  assert.deepEqual(failure, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'spawn-failed',
    id: 'pending-1',
    error: 'the session did not start in time',
  });
});

test('a dropped sessions push is silent — no resync-required', async () => {
  // A dropped `sessions` push (null session id) must not announce a resync: the
  // convergence bound is the next registry push or a reconnect, never a
  // `resync-required`. This pins the corrected R1 story.
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner, maxViewerBytes: 1 });
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(viewer);
  await helloTokened(agent);

  spawner.owned.add(4242);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    pid: 4242,
  });
  await barrier(agent);

  assert.equal(await viewer.tryNextSessions(200), undefined, 'no sessions frame at this cap');
  assert.equal(await viewer.tryNext(200), undefined, 'no resync-required for a dropped sessions push');
});

test('a pending row can be cancelled', async () => {
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });
  await viewer.next(2000);
  await viewer.nextSessions(2000); // the placeholder push

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'k1',
    sessionId: 'pending-1',
  });

  assert.equal((await viewer.next(2000)).ok, true);
  const after = await viewer.nextSessions(2000);
  assert.equal(after.pending, undefined, 'the cancelled placeholder must be gone');
  assert.deepEqual(spawner.killed, [4242], 'the pending child must be killed');

  // The cancelled child's real exit must not surface a failure: it was
  // deliberately stopped, not failed to start.
  spawner.fireExit(4242, 'exit');
  await barrier(viewer);
  assert.equal(await viewer.tryNext(150), undefined, 'no spawn-failed after a cancel');
});

test('two viewers cancelling one pending id: the first wins, the second is refused', async () => {
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner });
  const first = await connect(hub.viewerPort);
  const second = await connect(hub.viewerPort);
  await helloViewer(first);
  await helloViewer(second);

  first.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });
  await first.next(2000);
  await first.nextSessions(2000);
  await second.nextSessions(2000);

  first.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'k1',
    sessionId: 'pending-1',
  });
  assert.equal((await first.next(2000)).ok, true);
  await first.nextSessions(2000);
  await second.nextSessions(2000);

  second.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'k2',
    sessionId: 'pending-1',
  });
  const refused = await second.next(2000);
  assert.equal(refused.ok, false);
  assert.equal(refused.error, 'unknown session');
  assert.equal(spawner.killed.length, 1, 'the second cancel must not kill again');
  assert.equal(await second.tryNextSessions(200), undefined, 'no second broadcast');
});

test('a hub close with a pending spawn removes the listener, broadcasts nothing, and does not throw', async () => {
  const spawner = makeFakeSpawner();
  const hub = await createHub({
    token: TOKEN,
    tickets: createTicketStore(),
    viewerPort: 0,
    viewerHost: '127.0.0.1',
    spawner,
  });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });
  await viewer.next(2000);
  await viewer.nextSessions(2000);
  assert.equal(spawner.exitListeners.length, 1, 'the hub subscribed exactly once');

  await hub.close();

  assert.equal(spawner.exitListeners.length, 0, 'close must unsubscribe before the spawner');
  assert.equal(spawner.closeFinished, true, 'close must await the spawner');
  // A racing exit after close must neither throw nor emit a frame.
  assert.doesNotThrow(() => spawner.fireExit(4242, 'exit'));
  assert.equal(await viewer.tryNextSessions(150), undefined);
});
