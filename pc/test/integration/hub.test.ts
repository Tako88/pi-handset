// relay, backpressure and command dispatch.
// Split from the hub test file; test blocks are byte-exact.

import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { CLOSE_PROTOCOL } from '../../src/hub/hub.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

import { TOKEN, cleanup, startHub, barrier, closed, connect, helloTokened, underlyingSocket, helloViewer } from '../support/hub-harness.ts';

afterEach(cleanup);

test("a registered agent's stream event reaches a subscribed viewer", async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 1, text: 'hello viewer' },
  });

  const relayed = await viewer.next();
  assert.equal(relayed.type, 'event');
  assert.deepEqual(relayed.payload, { kind: 'stream', seq: 1, text: 'hello viewer' });
});

test("a content-free phase stream frame relays and does not close the agent", async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 1, phase: 'thinking' },
  });
  const phase = await viewer.next(2000);
  assert.deepEqual(phase.payload, { kind: 'stream', seq: 1, phase: 'thinking' });

  // A phase frame must not be treated as a protocol violation: the same agent
  // connection still relays the text that follows the thinking.
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 2, text: 'hi' },
  });
  const text = await viewer.next(2000);
  assert.deepEqual(text.payload, { kind: 'stream', seq: 2, text: 'hi' });
});

test("a registered agent's message, tool and status events relay verbatim", async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  const payloads = [
    { kind: 'message', role: 'assistant', content: 'hello' },
    { kind: 'tool', name: 'read', status: 'running' },
    { kind: 'status', message: 'compacting' },
  ];
  for (const payload of payloads) {
    agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'event', payload });
  }

  for (const payload of payloads) {
    const relayed = await viewer.next(2000);
    assert.equal(relayed.type, 'event');
    assert.deepEqual(relayed.payload, payload);
  }
});

test("a viewer's command reaches the registered agent and its command-result returns", async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c1',
    sessionId: 's1',
    name: 'prompt',
    args: { text: 'hi' },
  });

  const forwarded = await agent.next();
  assert.equal(forwarded.type, 'command');
  assert.equal(forwarded.id, 'c1');
  assert.equal(forwarded.sessionId, 's1');
  assert.equal(forwarded.name, 'prompt');

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c1',
    ok: true,
    queued: true,
  });

  const result = await viewer.next();
  // The hub is opaque: it forwards the parsed frame, so the optional field a
  // newer bridge adds survives without a hub change.
  assert.deepEqual(result, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c1',
    ok: true,
    queued: true,
  });
});

test('listCommands is forwarded to the agent and its result returns to the viewer', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c1',
    sessionId: 's1',
    name: 'listCommands',
  });

  const forwarded = await agent.next();
  assert.equal(forwarded.type, 'command');
  assert.equal(forwarded.id, 'c1');
  assert.equal(forwarded.sessionId, 's1');
  assert.equal(forwarded.name, 'listCommands');

  // The `commands` payload must reach the viewer verbatim: the hub applies no
  // per-name branch and no semantic merge.
  const commands = [
    { name: 'review', description: 'Review the working tree' },
    { name: 'implement-vetted' },
  ];
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c1',
    ok: true,
    commands,
  });

  const result = await viewer.next();
  assert.deepEqual(result, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c1',
    ok: true,
    commands,
  });
});

test('the new session commands are routed to the agent', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);

  // The four names M2 added to the bridge are also in the hub's copy of the
  // allowlist; a name the hub does not know is refused here and never reaches
  // pi, so this is the routing witness for the whole path.
  const names = ['listTree', 'sessionNew', 'sessionTree', 'sessionFork'] as const;
  for (const [index, name] of names.entries()) {
    const id = `c${index + 1}`;
    viewer.send({
      protocolVersion: PROTOCOL_VERSION,
      type: 'command',
      id,
      sessionId: 's1',
      name,
      args: { entryId: 'e1' },
    });

    const forwarded = await agent.next(2000);
    assert.equal(forwarded.type, 'command', `${name} must be forwarded, not refused`);
    assert.equal(forwarded.id, id);
    assert.equal(forwarded.sessionId, 's1');
    assert.equal(forwarded.name, name);
  }
});

test('two viewers issuing the same command id each get their own result', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const first = await connect(hub.viewerPort);
  const second = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(first);
  await helloViewer(second);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);

  const command = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c1',
    sessionId: 's1',
    name: 'prompt',
    args: { text: 'hi' },
  };
  first.send(command);
  second.send(command);
  await barrier(first);
  await barrier(second);

  // Both commands are forwarded, not collapsed into one.
  assert.equal((await agent.next(2000)).id, 'c1');
  assert.equal((await agent.next(2000)).id, 'c1');

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'command-result', id: 'c1', ok: true, error: 'one' });
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'command-result', id: 'c1', ok: true, error: 'two' });

  const results = [await first.next(2000), await second.next(2000)];
  assert.deepEqual(
    results.map((r) => r.error).sort(),
    ['one', 'two'],
    'each viewer must get exactly one result, with none overwritten',
  );
});

test('a command-result from an agent that does not own the session is ignored', async () => {
  const hub = await startHub();
  const owner = await connect(hub.agentPort);
  const other = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(owner);
  await helloTokened(other);
  await helloViewer(viewer);
  owner.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(owner);
  other.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's2' });
  await barrier(other);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c1',
    sessionId: 's1',
    name: 'prompt',
    args: { text: 'hi' },
  });
  await barrier(viewer);
  assert.equal((await owner.next(2000)).type, 'command');

  // The non-owner's spoofed answer must not reach the viewer at all; the real
  // owner's answer must be the first result the viewer sees.
  other.send({ protocolVersion: PROTOCOL_VERSION, type: 'command-result', id: 'c1', ok: true, error: 'spoofed' });
  await barrier(other);
  owner.send({ protocolVersion: PROTOCOL_VERSION, type: 'command-result', id: 'c1', ok: true, error: 'real' });

  const result = await viewer.next(2000);
  assert.equal(result.error, 'real');
});

test('an unknown command is rejected without reaching the agent', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c9',
    sessionId: 's1',
    name: 'exec',
    args: { cmd: 'rm -rf /' },
  });

  const result = await viewer.next();
  assert.equal(result.type, 'command-result');
  assert.equal(result.id, 'c9');
  assert.equal(result.ok, false);
  // Anchor the absence: a valid command sent afterwards must be the next thing
  // the agent sees, proving the unknown one was dropped, not merely in flight.
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c10',
    sessionId: 's1',
    name: 'prompt',
    args: { text: 'hi' },
  });
  const seen = await agent.next(2000);
  assert.equal(seen.type, 'command');
  assert.equal(seen.id, 'c10');
});

test('a command for an unknown session is rejected', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c7',
    sessionId: 'ghost',
    name: 'prompt',
    args: { text: 'hi' },
  });

  const result = await viewer.next();
  assert.equal(result.type, 'command-result');
  assert.equal(result.id, 'c7');
  assert.equal(result.ok, false);
});

test('a command beyond the pending cap is refused and not forwarded', async () => {
  const hub = await startHub({ maxPendingCommands: 2 });
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);

  const command = (id: string) => ({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId: 's1',
    name: 'prompt',
    args: { text: 'hi' },
  });
  viewer.send(command('c1'));
  viewer.send(command('c2'));
  viewer.send(command('c3'));

  // Positive first: two real deliveries prove the agent harness is live, so
  // the timeout-based "nothing more" below cannot pass on a dead reader.
  assert.equal((await agent.next(2000)).id, 'c1');
  assert.equal((await agent.next(2000)).id, 'c2');
  assert.equal(await agent.tryNext(300), undefined, 'c3 must not be forwarded');

  const refused = await viewer.next(2000);
  assert.equal(refused.type, 'command-result');
  assert.equal(refused.id, 'c3');
  assert.equal(refused.ok, false);
  assert.equal(refused.error, 'too many outstanding commands');

  // Answering c1 frees a slot; c4 is then forwarded, proving c3 was never
  // queued and c1's completion released the cap.
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'command-result', id: 'c1', ok: true });
  await barrier(agent);
  viewer.send(command('c4'));
  const forwarded = await agent.next(2000);
  assert.equal(forwarded.type, 'command');
  assert.equal(forwarded.id, 'c4');
});

test('the pending cap counts queued entries, not distinct ids', async () => {
  const hub = await startHub({ maxPendingCommands: 2 });
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);

  const command = (id: string) => ({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId: 's1',
    name: 'prompt',
    args: { text: 'hi' },
  });
  // The same id twice is two queued entries, not one distinct key.
  viewer.send(command('c1'));
  viewer.send(command('c1'));
  viewer.send(command('c2'));

  assert.equal((await agent.next(2000)).id, 'c1');
  assert.equal((await agent.next(2000)).id, 'c1');
  assert.equal(await agent.tryNext(300), undefined, 'c2 must not be forwarded');

  const refused = await viewer.next(2000);
  assert.equal(refused.type, 'command-result');
  assert.equal(refused.id, 'c2');
  assert.equal(refused.ok, false);
  assert.equal(refused.error, 'too many outstanding commands');
});

test('hub-local command refusals are delivered even when the viewer budget is exhausted', async () => {
  const hub = await startHub({ maxPendingCommands: 1, maxViewerBytes: 1 });
  const agent = await connect(hub.agentPort);
  await helloTokened(agent);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);

  const viewer = await connect(hub.viewerPort);
  // A 1-byte budget drops the post-auth `sessions` push, exactly as in the
  // list-dirs test; authenticate raw and do not wait for it.
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });
  await barrier(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c1',
    sessionId: 's1',
    name: 'notACommand',
  });
  const unknownCommand = await viewer.next(2000);
  assert.equal(unknownCommand.type, 'command-result');
  assert.equal(unknownCommand.id, 'c1');
  assert.equal(unknownCommand.ok, false);
  assert.equal(unknownCommand.error, 'unknown command');

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c2',
    sessionId: 'ghost',
    name: 'prompt',
  });
  const unknownSession = await viewer.next(2000);
  assert.equal(unknownSession.type, 'command-result');
  assert.equal(unknownSession.id, 'c2');
  assert.equal(unknownSession.ok, false);
  assert.equal(unknownSession.error, 'unknown session');

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c3',
    sessionId: 's1',
    name: 'prompt',
  });
  await barrier(viewer);
  assert.equal(
    (await agent.next(2000)).id,
    'c3',
    'the first command is forwarded and fills the cap',
  );
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c4',
    sessionId: 's1',
    name: 'prompt',
  });
  const overCap = await viewer.next(2000);
  assert.equal(overCap.type, 'command-result');
  assert.equal(overCap.id, 'c4');
  assert.equal(overCap.ok, false);
  assert.equal(overCap.error, 'too many outstanding commands');
});

test('closing an agent socket removes its session and tells subscribers', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  agent.terminate();

  const gone = await viewer.next();
  assert.deepEqual(gone, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'session-gone',
    sessionId: 's1',
  });
});

test('a re-register for the same session replaces the old agent', async () => {
  const hub = await startHub();
  const first = await connect(hub.agentPort);
  const second = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(first);
  await helloTokened(second);
  await helloViewer(viewer);

  first.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(first);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  second.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(second);

  // The takeover first tells the retained subscriber to resync (its own test
  // asserts that frame too); consume it so the event relay below is unambiguous.
  assert.deepEqual(await viewer.next(2000), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'resync-required',
    sessionId: 's1',
    reason: 'reconnect',
  });

  // The session survives the old owner's replacement; the new owner's events
  // arrive. (The displaced agent's close is asserted in its own test.)
  second.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 1, text: 'from the new owner' },
  });
  const relayed = await viewer.next();
  assert.equal(relayed.type, 'event');
  assert.deepEqual(relayed.payload, { kind: 'stream', seq: 1, text: 'from the new owner' });
});

test("a re-register that replaces the agent tells the session's subscribers to resync", async () => {
  const hub = await startHub();
  const first = await connect(hub.agentPort);
  const second = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(first);
  await helloTokened(second);
  await helloViewer(viewer);

  first.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(first);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  second.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });

  assert.deepEqual(await viewer.next(2000), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'resync-required',
    sessionId: 's1',
    reason: 'reconnect',
  });
});

test('re-registering a session explicitly closes the displaced agent', async () => {
  const hub = await startHub();
  const first = await connect(hub.agentPort);
  const second = await connect(hub.agentPort);
  await helloTokened(first);
  await helloTokened(second);
  first.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(first);

  second.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });

  const { code, reason } = await closed(first, 3000);
  assert.equal(code, CLOSE_PROTOCOL);
  assert.match(reason, /taken over/i, 'the takeover must be visible, not incidental');
});

test('unsubscribing stops delivery to that viewer', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'unsubscribe', sessionId: 's1' });
  await barrier(viewer);

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 1, text: 'nobody should see this' },
  });
  await barrier(agent);

  // Anchor the absence: re-subscribing and sending seq 2 must make seq 2 the
  // viewer's next message. If the unsubscribe had failed, seq 1 would be first.
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 2, text: 'this one should arrive' },
  });

  const relayed = await viewer.next(2000);
  assert.equal(relayed.type, 'event');
  assert.equal((relayed.payload as { seq: number }).seq, 2);
});

test('exceeding the byte budget drops events, resyncs, and preserves agentState', async () => {
  const hub = await startHub({ maxViewerBytes: 4096, maxAuthAttempts: 1, authCloseDelayMs: 10 });
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  // A viewer that stops reading fills the socket buffer, then the hub's budget.
  underlyingSocket(viewer).pause();

  const text = 'x'.repeat(1024);
  const total = 3000;
  for (let seq = 1; seq <= total; seq++) {
    agent.send({
      protocolVersion: PROTOCOL_VERSION,
      type: 'event',
      payload: { kind: 'stream', seq, text },
    });
  }
  // Sent after the budget is exhausted: this event is dropped for the viewer,
  // but the hub must still have recorded the terminal state.
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'agent', state: 'settled' },
  });
  await barrier(agent);

  underlyingSocket(viewer).resume();

  let resync: Record<string, unknown> | undefined;
  for (let i = 0; i < total + 100; i++) {
    const message = await viewer.next(5000);
    if (message.type === 'resync-required') {
      resync = message;
      break;
    }
  }
  assert.notEqual(resync, undefined, 'the viewer must be told to resync');
  assert.equal(resync!.sessionId, 's1');
  assert.equal(resync!.reason, 'backpressure');

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 's1',
  });
  const forwarded = await agent.next(5000);
  assert.equal(forwarded.type, 'history-request');
  assert.equal(forwarded.sessionId, 's1');

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history',
    sessionId: 's1',
    entries: [],
    truncated: false,
  });

  // Events admitted before the first drop may still be in flight, so read past
  // them until the snapshot arrives.
  let snapshot: Record<string, unknown> | undefined;
  for (let i = 0; i < total + 100; i++) {
    const message = await viewer.next(5000);
    if (message.type === 'snapshot') {
      snapshot = message;
      break;
    }
  }
  assert.notEqual(snapshot, undefined);
  assert.equal(snapshot!.sessionId, 's1');
  assert.equal(snapshot!.lastSeq, total);
  assert.equal(snapshot!.agentState, 'settled');
});

test('a snapshot answering a history-request is delivered past the byte budget', async () => {
  // Root cause of the resync livelock: a snapshot produced in answer to a
  // `history-request` is a control *response*, not bulk relay. Budgeting it
  // meant a snapshot bigger than the viewer cap was dropped, which announced
  // another resync, whose request produced another oversized snapshot — a
  // stable loop. This test previously asserted the drop; that was the bug.
  const hub = await startHub({ maxViewerBytes: 4096 });
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(viewer);
  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agent);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId: 's1' });
  assert.equal((await agent.next(2000)).type, 'history-request');

  const entries = [{ seq: 1, text: 'x'.repeat(20_000) }];
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history',
    sessionId: 's1',
    entries,
    truncated: false,
  });

  const snapshot = await viewer.next(3000);
  assert.equal(snapshot.type, 'snapshot');
  assert.equal(snapshot.sessionId, 's1');
  assert.deepEqual(snapshot.entries, entries);
  // The response is not droppable, so no resync is announced for it.
  assert.equal(await viewer.tryNext(300), undefined);
});

test('resync is announced per session, not once per viewer connection', async () => {
  const hub = await startHub({ maxViewerBytes: 4096 });
  const agentA = await connect(hub.agentPort);
  const agentB = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloTokened(agentA);
  await helloTokened(agentB);
  await helloViewer(viewer);
  agentA.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's1' });
  await barrier(agentA);
  agentB.send({ protocolVersion: PROTOCOL_VERSION, type: 'register', sessionId: 's2' });
  await barrier(agentB);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's1' });
  await barrier(viewer);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'subscribe', sessionId: 's2' });
  await barrier(viewer);

  // One oversized event per session: each must get its own announcement.
  agentA.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 1, text: 'x'.repeat(20_000) },
  });
  assert.equal((await viewer.next(3000)).sessionId, 's1');

  agentB.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'stream', seq: 1, text: 'x'.repeat(20_000) },
  });
  assert.equal((await viewer.next(3000)).sessionId, 's2');
});

test('a settled event broadcasts agent-settled to every viewer with no raw duplicate', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  const subscribed = await connect(hub.viewerPort);
  const observer = await connect(hub.viewerPort);
  await helloTokened(agent);
  await helloViewer(subscribed);
  await helloViewer(observer);

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'work',
  });
  await barrier(agent);
  subscribed.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'subscribe',
    sessionId: 's1',
  });
  await barrier(subscribed);

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'settled', text: 'Done.', truncated: false },
  });

  // The settle is a notification concern, so it reaches a viewer that never
  // subscribed — unlike a relayed `event`, which is subscriber-scoped.
  const notice = await observer.next(2000);
  assert.deepEqual(notice, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'agent-settled',
    sessionId: 's1',
    label: 'work',
    text: 'Done.',
    truncated: false,
  });

  // The subscriber is a viewer too, so it also gets the broadcast. Drain it,
  // then prove no raw `event` carrying the settle follows: the `return` after
  // the broadcast is load-bearing, and without it every settle would be
  // delivered twice (once as this notice, once as a relayed event).
  assert.deepEqual(await subscribed.next(2000), notice);
  const relayed = await subscribed.tryNext(150);
  assert.equal(relayed, undefined, `expected no raw relay, got ${JSON.stringify(relayed)}`);
});
