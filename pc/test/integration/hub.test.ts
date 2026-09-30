import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';

import { WebSocket } from 'ws';

// Deliberately `.ts`, and deliberately written before `hub.ts` exists: the red
// run must fail with an unresolved import, not a loader error.
import {
  CLOSE_CAPABILITY,
  CLOSE_PROTOCOL,
  CLOSE_RATE_LIMITED,
  createHub,
} from '../../src/hub/hub.ts';
import { createTicketStore } from '../../src/hub/pairing.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

const TOKEN = 'a'.repeat(64);

const running: Array<{ close(): Promise<void> }> = [];
const clients: Client[] = [];

afterEach(async () => {
  // Never leak a socket or a listener: tear down clients, then hubs, even when
  // a test failed.
  for (const client of clients) {
    if (
      client.ws.readyState === WebSocket.OPEN ||
      client.ws.readyState === WebSocket.CONNECTING
    ) {
      client.ws.terminate();
    }
  }
  clients.length = 0;
  while (running.length > 0) {
    await running.pop()!.close();
  }
});

async function startHub(
  overrides: Partial<Parameters<typeof createHub>[0]> = {},
): Promise<Awaited<ReturnType<typeof createHub>>> {
  const hub = await createHub({
    token: TOKEN,
    tickets: createTicketStore(),
    viewerPort: 0,
    viewerHost: '127.0.0.1',
    ...overrides,
  });
  running.push(hub);
  return hub;
}

interface Client {
  readonly ws: WebSocket;
  readonly closed: Promise<{ code: number; reason: string }>;
  send(message: unknown): void;
  /** Resolves with the next reply message, or rejects after `timeoutMs`. */
  next(timeoutMs?: number): Promise<Record<string, unknown>>;
  /** Resolves with the next reply message, or `undefined` after `timeoutMs`. */
  tryNext(timeoutMs?: number): Promise<Record<string, unknown> | undefined>;
  /** Resolves with the next unsolicited `sessions` push, or rejects after `timeoutMs`. */
  nextSessions(timeoutMs?: number): Promise<Record<string, unknown>>;
  /** Resolves with the next `sessions` push, or `undefined` after `timeoutMs`. */
  tryNextSessions(timeoutMs?: number): Promise<Record<string, unknown> | undefined>;
  terminate(): void;
}

interface MessageQueue {
  push(message: Record<string, unknown>): void;
  next(timeoutMs: number): Promise<Record<string, unknown>>;
  tryNext(timeoutMs: number): Promise<Record<string, unknown> | undefined>;
}

/**
 * A FIFO with at most one pending waiter. `ws` delivers messages in order, so a
 * promise-based reader is enough.
 */
function messageQueue(): MessageQueue {
  const items: Record<string, unknown>[] = [];
  let waiter: ((value: Record<string, unknown>) => void) | null = null;

  function next(timeoutMs: number): Promise<Record<string, unknown>> {
    const queued = items.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        waiter = null;
        reject(new Error('timed out waiting for a message'));
      }, timeoutMs);
      waiter = (value) => {
        clearTimeout(timer);
        resolve(value);
      };
    });
  }

  return {
    push(message) {
      if (waiter !== null) {
        const resolve = waiter;
        waiter = null;
        resolve(message);
      } else {
        items.push(message);
      }
    },
    next,
    async tryNext(timeoutMs) {
      try {
        return await next(timeoutMs);
      } catch {
        return undefined;
      }
    },
  };
}

/**
 * A cross-socket barrier: `ws` auto-responds to a ping with a pong, and the
 * server processes this socket's frames in order, so once the pong round-trips
 * every message sent before it on this socket has been handled by the hub.
 */
function barrier(client: Client): Promise<void> {
  return new Promise((resolve) => {
    client.ws.once('pong', () => resolve());
    client.ws.ping();
  });
}

/** Awaits a close, rejecting after a bound so a regression fails fast. */
function closed(
  client: Client,
  timeoutMs = 2000,
): Promise<{ code: number; reason: string }> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('timed out waiting for the socket to close')),
      timeoutMs,
    );
    client.closed.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

function connect(port: number): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const messages = messageQueue();
  const sessions = messageQueue();

  ws.on('message', (data) => {
    const message = JSON.parse(String(data)) as Record<string, unknown>;
    // `sessions` is unsolicited registry traffic. Keeping it out of the reply
    // queue lets a test read either stream without interleaving noise; the
    // sessions-specific tests read it explicitly via `nextSessions`.
    (message.type === 'sessions' ? sessions : messages).push(message);
  });

  const closed = new Promise<{ code: number; reason: string }>((resolve) => {
    ws.once('close', (code, reason) => resolve({ code, reason: String(reason) }));
  });

  return new Promise((resolve, reject) => {
    ws.once('error', reject);
    ws.once('open', () => {
      const client: Client = {
        ws,
        closed,
        send: (message) => ws.send(JSON.stringify(message)),
        next: (timeoutMs = 2000) => messages.next(timeoutMs),
        tryNext: (timeoutMs = 300) => messages.tryNext(timeoutMs),
        nextSessions: (timeoutMs = 2000) => sessions.next(timeoutMs),
        tryNextSessions: (timeoutMs = 300) => sessions.tryNext(timeoutMs),
        terminate: () => ws.terminate(),
      };
      clients.push(client);
      resolve(client);
    });
  });
}

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

async function helloTokened(client: Client): Promise<void> {
  client.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });
  await barrier(client);
}

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

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'command-result', id: 'c1', ok: true });

  const result = await viewer.next();
  assert.deepEqual(result, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c1',
    ok: true,
  });
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

interface PausableSocket {
  pause(): void;
  resume(): void;
}

/**
 * The underlying TCP socket, paused to make a viewer genuinely slow. A missing
 * `_socket` means `ws` changed its internals; say so explicitly rather than
 * failing with an opaque undefined error.
 */
function underlyingSocket(client: Client): PausableSocket {
  const socket = (client.ws as unknown as { _socket?: PausableSocket })._socket;
  if (socket === undefined) {
    throw new Error('ws internals changed: WebSocket has no _socket to pause');
  }
  return socket;
}

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

/**
 * Authenticates a viewer and asserts the session list it is pushed on
 * authentication lands in the sessions queue.
 */
async function helloViewer(client: Client): Promise<void> {
  await helloTokened(client);
  const first = await client.nextSessions(2000);
  assert.equal(first.type, 'sessions', 'a viewer is pushed the session list on auth');
}

test('a viewer is pushed the current session list — empty — on authentication', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });

  assert.deepEqual(await viewer.nextSessions(2000), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'sessions',
    sessions: [],
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
    { sessionId: 's1', label: 'ticketed', agentState: 'idle' },
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
    { sessionId: 's1', label: 'late', agentState: 'idle' },
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
    sessions: [{ sessionId: 's1', label: 'my session', agentState: 'idle' }],
  };
  assert.deepEqual(await first.nextSessions(2000), expected);
  assert.deepEqual(await second.nextSessions(2000), expected);
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
    { sessionId: 's1', label: 'streamer', agentState: 'idle' },
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
    { sessionId: 's1', label: 'streamer', agentState: 'running' },
  ]);

  // A second transition pushes again, so the first push was not a one-off.
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'agent', state: 'settled' },
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'streamer', agentState: 'settled' },
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
    { sessionId: 's1', label: 'first', agentState: 'idle' },
  ]);

  // A distinct, non-default state before the takeover: with both sides `idle`
  // the test could not tell "preserved" from "reset to the register default".
  firstAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: { kind: 'agent', state: 'running' },
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'first', agentState: 'running' },
  ]);

  secondAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    name: 'second',
  });
  assert.deepEqual((await viewer.nextSessions(2000)).sessions, [
    { sessionId: 's1', label: 'second', agentState: 'running' },
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
    { sessionId: 's1', label: 'budgeted', agentState: 'idle' },
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
    { sessionId: 's2', label: 'beta', agentState: 'idle' },
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
    },
    { sessionId: 's2', label: 'beta', agentState: 'idle' },
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
