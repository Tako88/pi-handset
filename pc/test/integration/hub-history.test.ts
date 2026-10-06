// history paging and replay.
// Split from the hub test file; test blocks are byte-exact.

import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { CLOSE_PROTOCOL } from '../../src/hub/hub.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

import { cleanup, startHub, barrier, closed, connect, helloTokened, helloViewer } from '../support/hub-harness.ts';

afterEach(cleanup);

test('a history-request with an invalid sinceSeq is closed as a protocol violation', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
    sinceSeq: -1,
  });

  const { code } = await closed(viewer, 3000);
  assert.equal(code, CLOSE_PROTOCOL);
});

test('concurrent history requests for one session coalesce into one agent request', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const first = await connect(hub.viewerPort);
  const second = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(first);
  await helloViewer(second);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  first.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(first);
  second.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(second);

  first.send({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId: 's1' });
  second.send({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId: 's1' });
  await barrier(first);
  await barrier(second);

  const forwarded = await agent.next(2000);
  assert.equal(forwarded.type, 'history-request');
  // Anchor: a viewer command sent now must be the agent's next message, proving
  // the second history-request was coalesced rather than merely in flight.
  first.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c1',
    sessionId: 's1',
    name: 'prompt',
    args: { text: 'hi' },
  });
  const nextToAgent = await agent.next(2000);
  assert.equal(nextToAgent.type, 'command');
  assert.equal(nextToAgent.id, 'c1');

  const entries = [{ seq: 1, text: 'hi' }];
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history',
    sessionId: 's1',
    entries,
    truncated: false,
  });

  for (const viewer of [first, second]) {
    const snapshot = await viewer.next(2000);
    assert.equal(snapshot.type, 'snapshot');
    assert.equal(snapshot.sessionId, 's1');
    assert.deepEqual(snapshot.entries, entries);
  }
});

test('the forwarded history-request carries the cursor', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
    cursor: 'c:1',
  });
  await barrier(viewer);

  const forwarded = await agent.next(2000);
  assert.equal(forwarded.type, 'history-request');
  assert.equal(forwarded.sessionId, 's1');
  assert.equal(forwarded.cursor, 'c:1');
});

test('two viewers with different cursors each get their own page', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const first = await connect(hub.viewerPort);
  const second = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(first);
  await helloViewer(second);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  first.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(first);
  second.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(second);

  first.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
    cursor: 'A:1',
  });
  second.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
    cursor: 'B:2',
  });
  await barrier(first);
  await barrier(second);

  // Two distinct cursors are forwarded separately. The fake agent keys its
  // replies off the forwarded cursor on purpose: if it sent a fixed frame the
  // hub would not be the thing deciding which viewer gets which page, and the
  // reds under NC-6/7/8 would be vacuous.
  const frames = [await agent.next(2000), await agent.next(2000)];
  assert.deepEqual(
    frames.map((frame) => frame.cursor).sort(),
    ['A:1', 'B:2'],
    'each cursor is forwarded in its own history-request',
  );

  const pageA = [{ seq: 1, text: 'older A' }];
  const pageB = [{ seq: 2, text: 'older B' }];
  const pages: Record<string, unknown[]> = { 'A:1': pageA, 'B:2': pageB };
  for (const frame of frames) {
    agent.send({
      protocolVersion: PROTOCOL_VERSION,
      type: 'history',
      sessionId: 's1',
      cursor: frame.cursor,
      entries: pages[String(frame.cursor)],
      truncated: true,
    });
  }

  const snapshotA = await first.next(2000);
  assert.equal(snapshotA.type, 'snapshot');
  assert.equal(snapshotA.cursor, 'A:1');
  assert.deepEqual(snapshotA.entries, pageA);
  const snapshotB = await second.next(2000);
  assert.equal(snapshotB.type, 'snapshot');
  assert.equal(snapshotB.cursor, 'B:2');
  assert.deepEqual(snapshotB.entries, pageB);
});

test('two viewers with the same cursor coalesce into one agent request', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const first = await connect(hub.viewerPort);
  const second = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(first);
  await helloViewer(second);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  first.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(first);
  second.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(second);

  first.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
    cursor: 'X:9',
  });
  second.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
    cursor: 'X:9',
  });
  await barrier(first);
  await barrier(second);

  const forwarded = await agent.next(2000);
  assert.equal(forwarded.type, 'history-request');
  // Anchor: a viewer command sent now must be the agent's next message, proving
  // the second history-request was coalesced rather than merely in flight.
  first.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c1',
    sessionId: 's1',
    name: 'prompt',
    args: { text: 'hi' },
  });
  const nextToAgent = await agent.next(2000);
  assert.equal(nextToAgent.type, 'command');
  assert.equal(nextToAgent.id, 'c1');

  const entries = [{ seq: 1, text: 'hi' }];
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history',
    sessionId: 's1',
    cursor: forwarded.cursor,
    entries,
    truncated: false,
  });

  for (const viewer of [first, second]) {
    const snapshot = await viewer.next(2000);
    assert.equal(snapshot.type, 'snapshot');
    assert.equal(snapshot.sessionId, 's1');
    assert.deepEqual(snapshot.entries, entries);
  }
});

test('a tokenless history is dropped when only a cursor request is pending', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
    cursor: 'x:1',
  });
  await barrier(viewer);
  const forwarded = await agent.next(2000);
  assert.equal(forwarded.cursor, 'x:1');

  // The fake agent answers the wrong, tokenless frame on purpose: this is the
  // deleted FIFO guess. The hub must drop it — the requester is the cursor's
  // group, not "any pending viewer".
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history',
    sessionId: 's1',
    entries: [{ seq: 0, text: 'wrong' }],
    truncated: false,
  });
  assert.equal(await viewer.tryNext(300), undefined, 'a tokenless frame is not delivered');

  // The cursor's group survived the drop, so the real answer still lands.
  const entries = [{ seq: 1, text: 'right' }];
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history',
    sessionId: 's1',
    cursor: 'x:1',
    entries,
    truncated: false,
  });
  const snapshot = await viewer.next(2000);
  assert.equal(snapshot.type, 'snapshot');
  assert.deepEqual(snapshot.entries, entries);
});

test('a delivered snapshot copies older and olderCursor from the agent frame', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
    cursor: 'x:1',
  });
  await barrier(viewer);

  // Keyed off the forwarded cursor, as H1 is: a fixed frame would let the fake
  // agent, not the hub, decide which page lands, making the copies vacuous.
  const forwarded = await agent.next(2000);
  assert.equal(forwarded.type, 'history-request');
  assert.equal(forwarded.cursor, 'x:1');

  const entries = [{ seq: 1, text: 'older page' }];
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history',
    sessionId: 's1',
    cursor: forwarded.cursor,
    older: true,
    olderCursor: 'y:2',
    entries,
    truncated: true,
  });

  const snapshot = await viewer.next(2000);
  assert.equal(snapshot.type, 'snapshot');
  assert.equal(snapshot.cursor, 'x:1');
  assert.equal(snapshot.older, true);
  assert.equal(snapshot.olderCursor, 'y:2');
  assert.deepEqual(snapshot.entries, entries);
  assert.equal(snapshot.truncated, true);

  // A second page whose frame omits those fields: the hub copies, it does not
  // invent, so they must stay absent rather than default to anything.
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
    cursor: 'x:2',
  });
  await barrier(viewer);
  const forwarded2 = await agent.next(2000);
  assert.equal(forwarded2.cursor, 'x:2');

  const newest = [{ seq: 2, text: 'newest page' }];
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history',
    sessionId: 's1',
    cursor: forwarded2.cursor,
    entries: newest,
    truncated: false,
  });
  const snapshot2 = await viewer.next(2000);
  assert.equal(snapshot2.type, 'snapshot');
  assert.equal(snapshot2.cursor, 'x:2');
  assert.equal('older' in snapshot2, false, 'an omitted older stays absent');
  assert.equal('olderCursor' in snapshot2, false, 'an omitted olderCursor stays absent');
});

test('a history-request with an invalid cursor is closed as a protocol violation', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
    cursor: 42,
  });

  const { code } = await closed(viewer, 3000);
  assert.equal(code, CLOSE_PROTOCOL);
});
