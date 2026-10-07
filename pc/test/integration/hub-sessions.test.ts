// the session registry and session-list pushes.
// Split from the hub test file; test blocks are byte-exact.

import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { createTicketStore } from '../../src/hub/pairing.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

import { TOKEN, cleanup, startHub, barrier, connect, helloTokened, helloViewer } from '../support/hub-harness.ts';

afterEach(cleanup);

test('a viewer is pushed the current session list — empty — on authentication', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });

  assert.deepEqual(await viewer.nextSessions(2000), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'sessions',
    sessions: [],
    capabilities: ['list-dirs', 'project-session', 'session-control', 'attachments'],
  });
});

test('a viewer that pairs with a ticket is also pushed the session list', async () => {
  const tickets = createTicketStore();
  const ticket = tickets.issue();
  const hub = await startHub({ tickets });
  const agent = await connect(hub.agentPort);
  await helloTokened(agent);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'ticketed',
  });
  await barrier(agent);

  // `authenticate` pushes the list on both branches; only the token branch was
  // covered, so a regression that dropped the pair-branch push would slip by.
  const viewer = await connect(hub.viewerPort);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', ticket });
  assert.equal((await viewer.next(2000)).type, 'paired');
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'ticketed', agentState: 'idle', origin: 'pc' },
  ]);
});

test('a viewer that authenticates after a session registered is pushed it', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  await helloTokened(agent);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'late',
  });
  await barrier(agent);

  // Every other content assertion authenticates first; a late joiner must be
  // handed the sessions that already exist, not an empty list.
  const viewer = await connect(hub.viewerPort);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'late', agentState: 'idle', origin: 'pc' },
  ]);
});

test('a register carrying replaces surfaces replacesSessionId in the sessions push', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agent);

  // The bridge names the session it just replaced on the successor's register;
  // the hub republishes it so the app can follow the replacement.
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's2',
    name: 'successor',
    replaces: 's1',
  });

  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    {
      sessionId: 's2',
      label: 'successor',
      agentState: 'idle',
      origin: 'pc',
      replacesSessionId: 's1',
    },
  ]);
});

test('registering an agent pushes an updated session list to every authenticated viewer', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const first = await connect(hub.viewerPort);
  const second = await connect(hub.viewerPort);
  await helloViewer(first);
  await helloViewer(second);
  await helloTokened(agent);

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'my session',
  });

  const expected = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'sessions',
    sessions: [{ sessionId: 's1', label: 'my session', agentState: 'idle', origin: 'pc' }],
    capabilities: ['list-dirs', 'project-session', 'session-control', 'attachments'],
  };
  assert.deepEqual(await first.nextSessions(2000), expected);
  assert.deepEqual(await second.nextSessions(2000), expected);
});

test('a re-register with an unchanged label does not push the session list again', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agent);

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'same',
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'same', agentState: 'idle', origin: 'pc' },
  ]);

  // The bridge re-registers on every reconnect and on every unchanged prompt;
  // an identical label must not spend a broadcast that every viewer redraws.
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'same',
  });
  await barrier(agent);
  assert.equal(await viewer.tryNextSessions(300), undefined);

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'changed',
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'changed', agentState: 'idle', origin: 'pc' },
  ]);
});

test('a re-register on the same connection does not tell viewers to resync', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  await helloTokened(agent);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'same',
  });
  await barrier(agent);

  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  // The same connection re-registering with a new label is a refresh, not a
  // takeover: the registry push is expected, a resync is not.
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'changed',
  });

  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'changed', agentState: 'idle', origin: 'pc' },
  ]);
  assert.equal(await viewer.tryNext(300), undefined);
});

test('stream events do not push the session list; an agent-state transition does', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agent);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'streamer',
  });
  // The registration push is the anchor that the viewer is receiving registry
  // traffic at all.
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'streamer', agentState: 'idle', origin: 'pc' },
  ]);

  // A burst of stream deltas bumps `lastSeq` but is not a registry change: no
  // push may follow, or the session list would broadcast once per token.
  for (let seq = 1; seq <= 5; seq++) {
    agent.send({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq, text: 'x' },
    });
  }
  await barrier(agent);

  // The transition idle -> running is the one thing a session list exists to
  // show. If the stream burst above pushed too, this read would get that push
  // (still `idle`) rather than the transition.
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'agent', state: 'running' },
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'streamer', agentState: 'running', origin: 'pc' },
  ]);

  // A second transition pushes again, so the first push was not a one-off.
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'agent', state: 'settled' },
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'streamer', agentState: 'settled', origin: 'pc' },
  ]);
});

test('losing an agent pushes an updated, now-empty session list', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agent);

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  assert.equal(((await viewer.nextSessions(2000)).sessions as unknown[]).length, 1);

  agent.terminate();

  const update = await viewer.nextSessions(2000);
  assert.equal(update.type, 'sessions');
  assert.deepEqual(update.sessions, []);
});

test('a takeover replaces the label but preserves the tracked session state', async () => {
  const hub = await startHub();
  const firstAgent = await connect(hub.agentPort);
  const secondAgent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(firstAgent);
  await helloTokened(secondAgent);

  firstAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'first',
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'first', agentState: 'idle', origin: 'pc' },
  ]);

  // A distinct, non-default state before the takeover: with both sides `idle`
  // the test could not tell "preserved" from "reset to the register default".
  firstAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'agent', state: 'running' },
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'first', agentState: 'running', origin: 'pc' },
  ]);

  secondAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'second',
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'second', agentState: 'running', origin: 'pc' },
  ]);
});

test('the agent listener never receives a sessions message', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);

  assert.equal(
    await agent.tryNextSessions(200),
    undefined,
    'the sessions push is viewer-only; the agent listener is never sent one',
  );
});

test('the session list is delivered when it fits and dropped whole when it does not', async () => {
  // Control: with room to spare the registration push arrives, on the same
  // `pushSessions` -> `sendToViewer` path the over-budget case uses. Without
  // this, the `undefined` below would also pass if no push were attempted.
  const roomy = await startHub({ maxViewerBytes: 1024 });
  const roomyAgent = await connect(roomy.agentPort);
  const roomyViewer = await connect(roomy.viewerPort);
  await helloViewer(roomyViewer);
  await helloTokened(roomyAgent);
  roomyAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'budgeted',
  });
  assert.deepEqual((await roomyViewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'budgeted', agentState: 'idle', origin: 'pc' },
  ]);

  // The identical push under a budget too small for it is dropped whole, not
  // sent raw. Auth's own (also over-budget) push is why this does not use
  // `helloViewer`, which would wait for a push that is deliberately dropped.
  const tiny = await startHub({ maxViewerBytes: 8 });
  const tinyAgent = await connect(tiny.agentPort);
  const tinyViewer = await connect(tiny.viewerPort);
  await helloTokened(tinyAgent);
  tinyViewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });
  await barrier(tinyViewer);
  tinyAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'budgeted',
  });
  await barrier(tinyAgent);

  assert.equal(
    await tinyViewer.tryNextSessions(200),
    undefined,
    'an over-budget sessions push must be dropped whole, not sent raw',
  );
});

test('the session list is every registered session, in sessionId order, with no register-only fields', async () => {
  const hub = await startHub();
  const agentB = await connect(hub.agentPort);
  const agentA = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agentB);
  await helloTokened(agentA);

  // Registered out of id order, and carrying fields the summary must not leak.
  agentB.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's2',
    name: 'beta',
    cwd: '/home/user/beta',
    model: 'claude-sonnet-4',
    pid: 4242,
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's2', label: 'beta', agentState: 'idle', origin: 'pc' },
  ]);

  agentA.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    sessionFile: '/home/user/.pi/sessions/1.jsonl',
  });
  const update = await viewer.nextSessions(2000);
  const summaries = update.sessions as Array<{ sessionId: string }>;
  assert.deepEqual(summaries.map((session) => session.sessionId), ['s1', 's2']);
  assert.deepEqual(update.sessions, [
    {
      sessionId: 's1',
      label: '1.jsonl',
      agentState: 'idle',
      origin: 'pc',
    },
    { sessionId: 's2', label: 'beta', agentState: 'idle', origin: 'pc' },
  ]);
});

test('a label derived from a path is a basename, never a full path', async () => {
  const hub = await startHub();
  const agentFile = await connect(hub.agentPort);
  const agentCwd = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agentFile);
  await helloTokened(agentCwd);

  // A session registered with no `name` must not publish an absolute path to a
  // viewer; the last path component is the useful, leakage-free part.
  agentFile.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    sessionFile: '/home/user/.pi/sessions/1.jsonl',
  });
  const fromFile = ((await viewer.nextSessions(2000)).sessions as Array<{
    sessionId: string;
    label: string;
  }>).find((session) => session.sessionId === 's1')!;
  assert.equal(fromFile.label, '1.jsonl');
  assert.ok(!fromFile.label.includes('/'), 'a sessionFile label must carry no path separator');

  agentCwd.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's2',
    cwd: '/home/user/beta',
  });
  const fromCwd = ((await viewer.nextSessions(2000)).sessions as Array<{
    sessionId: string;
    label: string;
  }>).find((session) => session.sessionId === 's2')!;
  assert.equal(fromCwd.label, 'beta');
  assert.ok(!fromCwd.label.includes('/'), 'a cwd label must carry no path separator');
});

test('the sessions frame advertises the hub capabilities', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });

  const frame = await viewer.nextSessions(2000);
  assert.deepEqual(
    frame.capabilities,
    ['list-dirs', 'project-session', 'session-control', 'attachments'],
    'a viewer gates folder browsing on this field; a pre-capabilities hub omits it',
  );
});
