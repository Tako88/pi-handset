/**
 * The pi bridge extension, driven against a stub `ExtensionAPI` and a fake
 * socket. Nothing here dials: the socket factory is injected, the clock is
 * injected, the RNG is injected, and the debug sink is injected.
 *
 * The tests are grouped by behaviour:
 * - normalization is total and explicit over the real `AssistantMessageEvent` list
 * - agent state is terminal on `agent_settled`, never on `agent_end`
 * - the command allowlist dispatches, everything else is refused
 * - reconnect is capped and jittered
 * - mode guard, silence, and lifecycle
 */

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import {
  EVENT_PAYLOAD_KINDS,
  MAX_RELAY_BYTES,
  PROTOCOL_VERSION,
} from '../src/protocol/protocol.ts';
import { writeDiscovery } from '../src/hub/discovery.ts';
import { loadOrCreateToken } from '../src/hub/auth.ts';

// Deliberately `.ts`, and deliberately written before the module exists: the
// red run must fail with an unresolved import, not a loader error.
import {
  RATE_LIMITED_RECONNECT_MS,
  computeBackoff,
  installBridge,
  isActiveMode,
  normalizeAssistantEvent,
  normalizeMessageEnd,
  projectHistory,
  readEndpoint,
} from './pi-droid-bridge.ts';
import type {
  AssistantMessageEvent,
  BridgeCloseEvent,
  BridgeCtx,
  BridgeDeps,
  BridgeHandler,
  BridgePi,
  BridgeSocket,
  MessageEndEvent,
} from './pi-droid-bridge.ts';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class FakeSocket implements BridgeSocket {
  readyState = 0;
  readonly sent: string[] = [];
  readonly closeCalls: Array<{ code?: number; reason?: string }> = [];
  private readonly listeners = new Map<string, Array<(event: any) => void>>();

  send(data: string): void {
    this.sent.push(data);
  }

  close(code?: number, reason?: string): void {
    this.closeCalls.push({ code, reason });
    this.readyState = 3;
    this.dispatch('close', { code, reason });
  }

  addEventListener(type: 'close', handler: (event: BridgeCloseEvent) => void): void;
  addEventListener(type: string, handler: (event: unknown) => void): void;
  addEventListener(type: string, handler: (event: any) => void): void {
    const list = this.listeners.get(type) ?? [];
    list.push(handler);
    this.listeners.set(type, list);
  }

  open(): void {
    this.readyState = 1;
    this.dispatch('open', {});
  }

  message(object: unknown): void {
    this.dispatch('message', { data: JSON.stringify(object) });
  }

  drop(code?: number, reason?: string): void {
    this.readyState = 3;
    this.dispatch('close', { code, reason });
  }

  private dispatch(type: string, event: unknown): void {
    for (const handler of this.listeners.get(type) ?? []) handler(event);
  }
}

class StubPi implements BridgePi {
  readonly handlers = new Map<string, BridgeHandler>();
  readonly userMessages: Array<{ content: string; options?: { deliverAs?: string } }> = [];
  readonly models: unknown[] = [];
  readonly thinkingLevels: string[] = [];
  readonly sessionNames: string[] = [];
  modelAccepted = true;
  private sessionName: string | undefined;

  on(event: string, handler: BridgeHandler): () => void {
    this.handlers.set(event, handler);
    return () => this.handlers.delete(event);
  }

  sendUserMessage(content: string, options?: { deliverAs?: 'steer' | 'followUp' }): void {
    this.userMessages.push({ content, options });
  }

  async setModel(model: unknown): Promise<boolean> {
    this.models.push(model);
    return this.modelAccepted;
  }

  setThinkingLevel(level: string): void {
    this.thinkingLevels.push(level);
  }

  setSessionName(name: string): void {
    this.sessionNames.push(name);
    this.sessionName = name;
  }

  getSessionName(): string | undefined {
    return this.sessionName;
  }
}

interface TestCtx extends BridgeCtx {
  aborts(): number;
  compacts(): number;
}

function makeCtx(mode = 'tui'): TestCtx {
  let aborts = 0;
  let compacts = 0;
  const ctx: TestCtx = {
    mode,
    cwd: '/work',
    model: { id: 'test-model' },
    thinkingLevel: 'medium',
    sessionManager: {
      getSessionId: () => 'sess-1',
      getSessionFile: () => '/sessions/sess-1.jsonl',
      getEntries: () => [{ type: 'message', id: 'e1' }],
    },
    abort: () => {
      aborts += 1;
    },
    compact: () => {
      compacts += 1;
    },
    aborts: () => aborts,
    compacts: () => compacts,
  };
  return ctx;
}

interface Harness {
  pi: StubPi;
  sockets: FakeSocket[];
  writes: Array<{ stream: string; text: string }>;
  timers: Array<{ fn: () => void; ms: number }>;
  startCtx: TestCtx;
  start(mode?: string): TestCtx;
  fireTimer(index?: number): void;
}

function makeHarness(overrides: Partial<BridgeDeps> = {}): Harness {
  const pi = new StubPi();
  const sockets: FakeSocket[] = [];
  const writes: Array<{ stream: string; text: string }> = [];
  const timers: Array<{ fn: () => void; ms: number }> = [];
  let startCtx = makeCtx();
  const deps: BridgeDeps = {
    env: {},
    socketFactory: (url) => {
      void url;
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket;
    },
    resolveEndpoint: () => ({ url: 'ws://127.0.0.1:1234', token: 'tok' }),
    write: (stream, text) => writes.push({ stream, text }),
    rng: () => 0.5,
    setTimeout: (fn, ms) => {
      timers.push({ fn, ms });
      return timers.length;
    },
    clearTimeout: () => {},
    ...overrides,
  };
  installBridge(pi, deps);

  const start = (mode = 'tui'): TestCtx => {
    startCtx = makeCtx(mode);
    pi.handlers.get('session_start')!({ type: 'session_start', reason: 'startup' }, startCtx);
    return startCtx;
  };

  return {
    pi,
    sockets,
    writes,
    timers,
    get startCtx() {
      return startCtx;
    },
    start,
    fireTimer: (index = 0) => timers[index]!.fn(),
  };
}

function parsed(socket: FakeSocket): Array<Record<string, unknown>> {
  return socket.sent.map((text) => JSON.parse(text) as Record<string, unknown>);
}

function tick(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

async function sendCommand(
  _pi: StubPi,
  socket: FakeSocket,
  name: string,
  args?: unknown,
): Promise<void> {
  socket.message({ protocolVersion: PROTOCOL_VERSION, type: 'command', id: `c-${name}`, sessionId: 'sess-1', name, args });
  await tick();
}

// ---------------------------------------------------------------------------
// The real AssistantMessageEvent variant list (pi-ai/dist/types.d.ts).
// ---------------------------------------------------------------------------

const REAL_VARIANTS = [
  'start',
  'text_start',
  'text_delta',
  'text_end',
  'thinking_start',
  'thinking_delta',
  'thinking_end',
  'toolcall_start',
  'toolcall_delta',
  'toolcall_end',
  'done',
  'error',
] as const;

function sampleAssistantEvent(type: string): AssistantMessageEvent {
  const partial = { role: 'assistant', content: [] };
  switch (type) {
    case 'start':
      return { type: 'start', partial };
    case 'text_start':
      return { type: 'text_start', contentIndex: 0, partial };
    case 'text_delta':
      return { type: 'text_delta', contentIndex: 0, delta: 'hello', partial };
    case 'text_end':
      return { type: 'text_end', contentIndex: 0, content: 'hello', partial };
    case 'thinking_start':
      return { type: 'thinking_start', contentIndex: 0, partial };
    case 'thinking_delta':
      return { type: 'thinking_delta', contentIndex: 0, delta: 'hmm', partial };
    case 'thinking_end':
      return { type: 'thinking_end', contentIndex: 0, content: 'hmm', partial };
    case 'toolcall_start':
      return { type: 'toolcall_start', contentIndex: 0, partial };
    case 'toolcall_delta':
      return { type: 'toolcall_delta', contentIndex: 0, delta: '{}', partial };
    case 'toolcall_end':
      return {
        type: 'toolcall_end',
        contentIndex: 0,
        toolCall: { id: 't1', name: 'bash', arguments: {} },
        partial,
      };
    case 'done':
      return { type: 'done', reason: 'stop', message: { role: 'assistant', content: [] } };
    case 'error':
      return { type: 'error', reason: 'error', error: { errorMessage: 'boom' } };
    default:
      throw new Error(`no sample for ${type}`);
  }
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

test('a text_delta normalizes to a stream payload carrying the delta and the seq', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('text_delta'), 7);
  assert.deepEqual(result, { kind: 'emit', payload: { kind: 'stream', seq: 7, text: 'hello' } });
});

test('a done event normalizes to a message payload', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('done'), 1);
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal(result.payload.kind, 'message');
});

test('an error event normalizes to a status payload', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('error'), 1);
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal(result.payload.kind, 'status');
  assert.equal((result.payload as { message?: string }).message, 'boom');
});

test('every real AssistantMessageEvent variant is explicitly emitted or ignored', () => {
  for (const type of REAL_VARIANTS) {
    const result = normalizeAssistantEvent(sampleAssistantEvent(type), 1);
    assert.ok(
      result.kind === 'emit' || result.kind === 'ignore',
      `${type} returned neither emit nor ignore: ${JSON.stringify(result)}`,
    );
    if (result.kind === 'emit') {
      assert.ok(
        (EVENT_PAYLOAD_KINDS as readonly string[]).includes(result.payload.kind),
        `${type} emitted an unknown payload kind`,
      );
    } else {
      assert.ok(result.reason.length > 0, `${type} was ignored without a stated reason`);
    }
  }
});

test('thinking_delta is explicitly ignored, not silently dropped', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('thinking_delta'), 1);
  assert.equal(result.kind, 'ignore');
});

test('thinking_start emits a content-free phase frame with no reasoning text', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('thinking_start'), 4);
  assert.deepEqual(result, {
    kind: 'emit',
    payload: { kind: 'stream', seq: 4, phase: 'thinking' },
  });
  if (result.kind !== 'emit') return;
  // The whole point of the phase frame: it signals liveness without carrying a
  // single byte of reasoning. A `text` field of any value must fail this.
  assert.equal('text' in (result.payload as Record<string, unknown>), false);
});

test('toolcall_delta is explicitly ignored, not silently dropped', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('toolcall_delta'), 1);
  assert.equal(result.kind, 'ignore');
});

test('an unrecognized assistant event is explicitly ignored, never undefined', () => {
  const future = { type: 'future_variant' } as unknown as AssistantMessageEvent;
  const result = normalizeAssistantEvent(future, 1);
  assert.equal(result.kind, 'ignore');
  assert.match((result as { reason: string }).reason, /future_variant/);
});

test('a small done message is forwarded whole and not flagged truncated', () => {
  const message = { role: 'assistant', content: 'hi' };
  const result = normalizeAssistantEvent({ type: 'done', reason: 'stop', message }, 1);
  assert.deepEqual(result, { kind: 'emit', payload: { kind: 'message', message, truncated: false } });
});

test('an oversized done message is truncated and flagged, staying under the shared cap', () => {
  const huge = { role: 'assistant', content: 'x'.repeat(MAX_RELAY_BYTES + 1) };
  const result = normalizeAssistantEvent({ type: 'done', reason: 'stop', message: huge }, 1);
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal(result.payload.kind, 'message');
  assert.equal((result.payload as { truncated?: boolean }).truncated, true);
  const encoded = JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'event', payload: result.payload });
  assert.ok(
    Buffer.byteLength(encoded) <= MAX_RELAY_BYTES,
    'a truncated done event must fit the shared byte cap',
  );
});

// ---------------------------------------------------------------------------
// message_end — real pi's assistant-completion signal
// ---------------------------------------------------------------------------

test('a message_end carrying an assistant message emits exactly one message payload', () => {
  const message = { role: 'assistant', content: [{ type: 'text', text: 'hi' }] };
  const event: MessageEndEvent = { type: 'message_end', message };
  const result = normalizeMessageEnd(event);
  assert.deepEqual(result, {
    kind: 'emit',
    payload: { kind: 'message', message, truncated: false },
  });
});

test('a message_end carrying a user message is relayed as an own message', () => {
  const message = { role: 'user', content: 'hi' };
  const result = normalizeMessageEnd({ type: 'message_end', message });
  assert.deepEqual(result, {
    kind: 'emit',
    payload: { kind: 'message', message, truncated: false },
  });
});

test('a message_end carrying a toolResult message is relayed', () => {
  const message = {
    role: 'toolResult',
    toolCallId: 'call-1',
    toolName: 'read',
    content: [{ type: 'text', text: 'file body' }],
    isError: false,
  };
  const result = normalizeMessageEnd({ type: 'message_end', message });
  assert.deepEqual(result, {
    kind: 'emit',
    payload: { kind: 'message', message, truncated: false },
  });
});

test('a message_end carrying a custom message is ignored with a stated reason', () => {
  const result = normalizeMessageEnd({ type: 'message_end', message: { role: 'custom', content: 'x' } });
  assert.equal(result.kind, 'ignore');
  if (result.kind !== 'ignore') return;
  assert.match(result.reason, /custom/);
});

test('a message_end carrying a system message is ignored with a stated reason', () => {
  const result = normalizeMessageEnd({ type: 'message_end', message: { role: 'system', content: 'prompt' } });
  assert.equal(result.kind, 'ignore');
  if (result.kind !== 'ignore') return;
  assert.match(result.reason, /system/);
});

test('an oversized assistant message_end is truncated and flagged, staying under the shared cap', () => {
  const huge = { role: 'assistant', content: [{ type: 'text', text: 'x'.repeat(MAX_RELAY_BYTES + 1) }] };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal(result.payload.kind, 'message');
  assert.equal((result.payload as { truncated?: boolean }).truncated, true);
  const encoded = JSON.stringify({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: result.payload,
  });
  assert.ok(
    Buffer.byteLength(encoded) <= MAX_RELAY_BYTES,
    'a truncated message_end must fit the shared byte cap',
  );
});

test('an oversized toolResult message_end is replaced by a byte-count marker', () => {
  const huge = {
    role: 'toolResult',
    toolCallId: 'call-1',
    toolName: 'read',
    content: [{ type: 'text', text: 'x'.repeat(MAX_RELAY_BYTES + 1) }],
    isError: false,
  };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal((result.payload as { truncated?: boolean }).truncated, true);
  assert.deepEqual((result.payload as { message?: unknown }).message, {
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(huge)),
  });
});

test('the message_end handler relays assistant, user and toolResult messages and ignores other roles', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const handler = harness.pi.handlers.get('message_end')!;
  const assistant = { role: 'assistant', content: [{ type: 'text', text: 'done' }] };
  const user = { role: 'user', content: 'hi' };
  const toolResult = {
    role: 'toolResult',
    toolCallId: 'call-1',
    toolName: 'read',
    content: [{ type: 'text', text: 'file body' }],
    isError: false,
  };
  handler({ type: 'message_end', message: user }, harness.startCtx);
  handler({ type: 'message_end', message: assistant }, harness.startCtx);
  handler({ type: 'message_end', message: toolResult }, harness.startCtx);
  handler({ type: 'message_end', message: { role: 'system', content: 'prompt' } }, harness.startCtx);
  const emitted = parsed(socket)
    .slice(before)
    .filter((m) => (m.payload as { kind?: string })?.kind === 'message');
  // Per-role, not a single total: each relayed role must appear exactly once.
  assert.equal(emitted.length, 3, 'exactly one user, assistant and toolResult message must be relayed');
  const roles = emitted.map((m) => (m.payload as { message: { role: string } }).message.role);
  assert.deepEqual(roles, ['user', 'assistant', 'toolResult']);
  assert.deepEqual(emitted[0]!.payload, { kind: 'message', message: user, truncated: false });
  assert.deepEqual(emitted[1]!.payload, { kind: 'message', message: assistant, truncated: false });
  assert.deepEqual(emitted[2]!.payload, { kind: 'message', message: toolResult, truncated: false });
});

test('consecutive text deltas get strictly increasing stream seqs', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const update = (delta: string): void => {
    harness.pi.handlers.get('message_update')!(
      { type: 'message_update', message: {}, assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta, partial: {} } },
      harness.startCtx,
    );
  };
  update('a');
  update('b');
  const streams = parsed(socket).slice(before).filter((m) => (m.payload as { kind?: string })?.kind === 'stream');
  assert.deepEqual(streams.map((m) => (m.payload as { seq: number }).seq), [1, 2]);
});

// ---------------------------------------------------------------------------
// Agent state
// ---------------------------------------------------------------------------

test('agent_settled yields the terminal agent state', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('agent_settled')!({ type: 'agent_settled' }, harness.startCtx);
  const last = parsed(socket).at(-1)!;
  assert.deepEqual(last.payload, { kind: 'agent', state: 'settled' });
});

test('agent_start yields the running state', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('agent_start')!({ type: 'agent_start' }, harness.startCtx);
  const last = parsed(socket).at(-1)!;
  assert.deepEqual(last.payload, { kind: 'agent', state: 'running' });
});

test('agent_end does not yield the terminal state', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('agent_start')!({ type: 'agent_start' }, harness.startCtx);
  // The bridge deliberately does not subscribe to `agent_end`; if it ever does,
  // invoking the handler must still not settle the session.
  const agentEnd = harness.pi.handlers.get('agent_end');
  if (agentEnd !== undefined) agentEnd({ type: 'agent_end' }, harness.startCtx);
  const states = parsed(socket)
    .filter((m) => (m.payload as { kind?: string })?.kind === 'agent')
    .map((m) => (m.payload as { state: string }).state);
  assert.equal(states.at(-1), 'running');
  assert.equal(states.includes('settled'), false);
});

test('the terminal agent state is re-emitted after a reconnect', () => {
  const harness = makeHarness();
  harness.start();
  const first = harness.sockets[0]!;
  first.open();
  harness.pi.handlers.get('agent_settled')!({ type: 'agent_settled' }, harness.startCtx);
  first.drop();
  harness.fireTimer();
  const second = harness.sockets[1]!;
  second.open();
  const messages = parsed(second);
  assert.equal(messages[1]!.type, 'register');
  assert.deepEqual(messages[2]!.payload, { kind: 'agent', state: 'settled' });
});

// ---------------------------------------------------------------------------
// Command dispatch
// ---------------------------------------------------------------------------

test('prompt injects the text as a plain user message', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'hi' });
  assert.deepEqual(harness.pi.userMessages, [{ content: 'hi', options: {} }]);
});

test('steer injects the text with deliverAs steer', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'steer', { text: 'hi' });
  assert.deepEqual(harness.pi.userMessages, [{ content: 'hi', options: { deliverAs: 'steer' } }]);
});

test('followup injects the text with deliverAs followUp', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'followup', { text: 'hi' });
  assert.deepEqual(harness.pi.userMessages, [{ content: 'hi', options: { deliverAs: 'followUp' } }]);
});

test('abort aborts the active operation and acknowledges dispatch', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'abort');
  assert.equal(ctx.aborts(), 1);
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-abort',
    ok: true,
  });
});

test('setModel dispatches and reports the accepted boolean', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { model: { id: 'm2' } });
  assert.deepEqual(harness.pi.models, [{ id: 'm2' }]);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
});

test('setModel reports a rejected model as a failed command-result', async () => {
  const harness = makeHarness();
  harness.pi.modelAccepted = false;
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { model: { id: 'm2' } });
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('setThinkingLevel dispatches the level', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setThinkingLevel', { level: 'high' });
  assert.deepEqual(harness.pi.thinkingLevels, ['high']);
});

test('compact requests compaction', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'compact');
  assert.equal(ctx.compacts(), 1);
});

test('fetchHistory replies with a history message', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'fetchHistory');
  const history = parsed(socket).find((m) => m.type === 'history')!;
  assert.deepEqual(history.entries, [{ type: 'message', id: 'e1' }]);
  assert.equal(history.truncated, false);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
});

test('a history-request from the hub is answered with a history message', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  const history = parsed(socket).find((m) => m.type === 'history')!;
  assert.equal(history.sessionId, 'sess-1');
  assert.deepEqual(history.entries, [{ type: 'message', id: 'e1' }]);
});

test('a throwing getEntries on the history-request path does not escape and writes nothing', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  ctx.sessionManager.getEntries = () => {
    throw new Error('entries exploded');
  };
  assert.doesNotThrow(() => {
    socket.message({
      protocolVersion: PROTOCOL_VERSION,
      type: 'history-request',
      sessionId: 'sess-1',
    });
  });
  assert.deepEqual(harness.writes, []);
});

test('setSessionName sets the session name', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setSessionName', { name: 'Phone chat' });
  assert.deepEqual(harness.pi.sessionNames, ['Phone chat']);
});

// ---------------------------------------------------------------------------
// Refusals
// ---------------------------------------------------------------------------

test('exec is refused, not ignored', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'exec', { command: 'rm', args: ['-rf', '/'] });
  const result = parsed(socket).at(-1) as { type: string; ok: boolean };
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
});

test('shutdown is refused without shutting down', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'shutdown');
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('setActiveTools is refused', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setActiveTools', { tools: ['bash'] });
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('an unknown command is refused', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'definitelyNotACommand');
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('a command arriving after the session turns inert is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start('tui');
  const socket = harness.sockets[0]!;
  socket.open();
  // A future socket path must not be able to dispatch once the mode is inert;
  // the guard is re-checked at dispatch, not only at session_start.
  ctx.mode = 'json';
  await sendCommand(harness.pi, socket, 'prompt', { text: 'hi' });
  assert.deepEqual(harness.pi.userMessages, []);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('a command whose sessionId is not this session is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c-other',
    sessionId: 'other-session',
    name: 'abort',
  });
  await tick();
  assert.equal(ctx.aborts(), 0);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('refusal is not defeatable by casing or whitespace', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  for (const name of ['Prompt', 'PROMPT', ' prompt', 'prompt ', 'exec ', 'Shutdown', 'setactivetools']) {
    await sendCommand(harness.pi, socket, name, { text: 'hi' });
    const result = parsed(socket).at(-1) as { ok: boolean };
    assert.equal(result.ok, false, `${name} was not refused`);
  }
  assert.deepEqual(harness.pi.userMessages, []);
});

// ---------------------------------------------------------------------------
// Reconnect backoff
// ---------------------------------------------------------------------------

test('backoff never exceeds its cap across many attempts', () => {
  for (let attempt = 0; attempt <= 1000; attempt += 1) {
    const delay = computeBackoff(attempt, { rng: () => 1 });
    assert.ok(delay <= 30_000, `attempt ${attempt} yielded ${delay}`);
  }
});

test('backoff jitters between calls at the same attempt', () => {
  const low = computeBackoff(4, { rng: () => 0.1 });
  const high = computeBackoff(4, { rng: () => 0.9 });
  assert.notEqual(low, high);
});

test('a 4003 capability close does not schedule a reconnect', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.drop(4003);
  assert.equal(harness.timers.length, 0, 'a bridge capability bug must not retry forever');
});

test('a 4008 rate-limit close reconnects after a fixed longer delay', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.drop(4008);
  assert.equal(harness.timers.length, 1);
  assert.equal(harness.timers[0]!.ms, RATE_LIMITED_RECONNECT_MS);
  assert.ok(RATE_LIMITED_RECONNECT_MS > 500, 'the rate-limit wait exceeds the first backoff step');
  // Fired once, the reconnect is dialled and the next 4008 waits the same
  // fixed span rather than a jittered backoff step.
  harness.fireTimer();
  const second = harness.sockets[1]!;
  second.open();
  second.drop(4008);
  assert.equal(harness.timers[1]!.ms, RATE_LIMITED_RECONNECT_MS);
});

test('a dropped socket schedules a reconnect through the injected clock', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  assert.equal(harness.timers.length, 0);
  socket.drop();
  assert.equal(harness.timers.length, 1);
  assert.ok(harness.timers[0]!.ms <= 30_000);
});

test('reconnect resends hello, register and the current agent state', () => {
  const harness = makeHarness();
  harness.start();
  const first = harness.sockets[0]!;
  first.open();
  first.drop();
  harness.fireTimer();
  const second = harness.sockets[1]!;
  second.open();
  const types = parsed(second).map((m) => m.type);
  assert.deepEqual(types.slice(0, 2), ['hello', 'register']);
  assert.deepEqual(parsed(second)[2]!.payload, { kind: 'agent', state: 'idle' });
});

// ---------------------------------------------------------------------------
// Mode guard
// ---------------------------------------------------------------------------

test('tui and rpc are active modes', () => {
  assert.equal(isActiveMode('tui'), true);
  assert.equal(isActiveMode('rpc'), true);
});

test('json and print are inert modes', () => {
  assert.equal(isActiveMode('json'), false);
  assert.equal(isActiveMode('print'), false);
});

test('an inert mode opens no socket', () => {
  const harness = makeHarness();
  harness.start('print');
  assert.equal(harness.sockets.length, 0);
});

test('an inert mode writes nothing', () => {
  const harness = makeHarness();
  harness.start('json');
  assert.deepEqual(harness.writes, []);
});

// ---------------------------------------------------------------------------
// Silence
// ---------------------------------------------------------------------------

test('nothing is written without PI_DROID_DEBUG=1', () => {
  const harness = makeHarness({ resolveEndpoint: () => null });
  harness.start();
  assert.deepEqual(harness.writes, []);
});

test('debug output goes to stderr when PI_DROID_DEBUG=1', () => {
  const harness = makeHarness({ env: { PI_DROID_DEBUG: '1' }, resolveEndpoint: () => null });
  harness.start();
  assert.ok(harness.writes.length > 0);
  assert.ok(harness.writes.every((write) => write.stream === 'stderr'));
});

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

test('the factory opens no socket', () => {
  const harness = makeHarness();
  assert.equal(harness.sockets.length, 0);
});

test('the socket opens in session_start', () => {
  const harness = makeHarness();
  harness.start();
  assert.equal(harness.sockets.length, 1);
});

test('register carries the session identity', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.sessionId, 'sess-1');
  assert.equal(register.sessionFile, '/sessions/sess-1.jsonl');
  assert.equal(register.cwd, '/work');
  assert.equal(register.model, 'test-model');
  assert.equal(register.thinkingLevel, 'medium');
  assert.equal(register.mode, 'tui');
  assert.equal(register.pid, process.pid);
});

// ---------------------------------------------------------------------------
// Session labels
// ---------------------------------------------------------------------------

test('register carries the last user prompt as the label', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    { type: 'message', message: { role: 'assistant', content: 'reply' } },
    { type: 'message', message: { role: 'user', content: 'first' } },
    { type: 'message', message: { role: 'user', content: 'last prompt' } },
  ];
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, 'last prompt');
});

test('an explicit session name beats the last user prompt', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    { type: 'message', message: { role: 'user', content: 'last prompt' } },
  ];
  harness.pi.setSessionName('explicit');
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, 'explicit');
});

test('a label is sanitized', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    { type: 'message', message: { role: 'user', content: '  hello\n\n\tworld  ' } },
  ];
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, 'hello world');
});

test('a label truncates over code points, never splitting an emoji', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    { type: 'message', message: { role: 'user', content: '😀'.repeat(81) } },
  ];
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, '😀'.repeat(80));
  assert.equal(Array.from(register.name as string).length, 80);
});

test('an image-only user message puts no name on the wire', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    {
      type: 'message',
      message: { role: 'user', content: [{ type: 'image', data: 'x', mimeType: 'image/png' }] },
    },
  ];
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal('name' in register, false);
});

test('an empty session name falls back to the last prompt, never name: ""', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    { type: 'message', message: { role: 'user', content: 'last prompt' } },
  ];
  harness.pi.setSessionName('');
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, 'last prompt');
});

test('a mixed text+image prompt contributes only its text', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    {
      type: 'message',
      message: {
        role: 'user',
        content: [
          { type: 'image', data: 'x', mimeType: 'image/png' },
          { type: 'text', text: 'look  at this' },
        ],
      },
    },
  ];
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, 'look at this');
});

test('a throwing getSessionName still sends the register frame without a name', () => {
  const harness = makeHarness();
  harness.start();
  harness.pi.getSessionName = () => {
    throw new Error('boom');
  };
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.ok(register);
  assert.equal('name' in register, false);
});

test('a new user prompt re-registers with the new label', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  assert.equal(parsed(socket).filter((m) => m.type === 'register').length, 1);
  harness.pi.handlers.get('message_end')!(
    { type: 'message_end', message: { role: 'user', content: 'new topic' } },
    harness.startCtx,
  );
  const registers = parsed(socket).filter((m) => m.type === 'register');
  assert.equal(registers.length, 2);
  assert.equal(registers[1]!.name, 'new topic');
});

test('a repeated prompt with the same text does not re-register', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  const event = { type: 'message_end', message: { role: 'user', content: 'same' } };
  handler(event, harness.startCtx);
  handler(event, harness.startCtx);
  assert.equal(parsed(socket).filter((m) => m.type === 'register').length, 2);
});

test('an image-only prompt does not re-register', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('message_end')!(
    {
      type: 'message_end',
      message: { role: 'user', content: [{ type: 'image', data: 'x', mimeType: 'image/png' }] },
    },
    harness.startCtx,
  );
  assert.equal(parsed(socket).filter((m) => m.type === 'register').length, 1);
});

test('a non-user message_end does not re-register', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('message_end')!(
    { type: 'message_end', message: { role: 'assistant', content: 'reply' } },
    harness.startCtx,
  );
  assert.equal(parsed(socket).filter((m) => m.type === 'register').length, 1);
});

test('setSessionName re-registers with the new name', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setSessionName', { name: 'Phone chat' });
  const registers = parsed(socket).filter((m) => m.type === 'register');
  assert.equal(registers.length, 2);
  assert.equal(registers[1]!.name, 'Phone chat');
});

test('a throwing getEntries during register still sends the register frame', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  (harness.pi as { getSessionName?: unknown }).getSessionName = undefined;
  ctx.sessionManager.getEntries = () => {
    throw new Error('entries exploded');
  };
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.ok(register);
  assert.equal('name' in register, false);
});

test('a session_info_changed event from a TUI rename re-registers', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.setSessionName('tui rename');
  harness.pi.handlers.get('session_info_changed')!(
    { type: 'session_info_changed', name: 'tui rename' },
    harness.startCtx,
  );
  const registers = parsed(socket).filter((m) => m.type === 'register');
  assert.equal(registers.length, 2);
  assert.equal(registers[1]!.name, 'tui rename');
});

test('session_shutdown closes the socket', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  assert.equal(socket.closeCalls.length, 1);
});

test('session_shutdown is idempotent', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  assert.equal(socket.closeCalls.length, 1);
});

test('a new session_start closes the previous socket and re-registers', () => {
  const harness = makeHarness();
  harness.start();
  const first = harness.sockets[0]!;
  first.open();
  harness.start('tui');
  const second = harness.sockets[1]!;
  second.open();
  assert.equal(first.closeCalls.length, 1);
  assert.equal(second.sent.filter((text) => JSON.parse(text).type === 'register').length, 1);
});

test('the retained context follows a session switch', async () => {
  const harness = makeHarness();
  harness.start();
  harness.sockets[0]!.open();
  const secondCtx = harness.start();
  const secondSocket = harness.sockets[1]!;
  secondSocket.open();
  await sendCommand(harness.pi, secondSocket, 'abort');
  assert.equal(secondCtx.aborts(), 1);
});

test('commands arriving after shutdown are ignored', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  await sendCommand(harness.pi, socket, 'prompt', { text: 'late' });
  assert.deepEqual(harness.pi.userMessages, []);
});

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

test('the bridge does not import the ws package', () => {
  const source = readFileSync(new URL('./pi-droid-bridge.ts', import.meta.url), 'utf8');
  assert.equal(/from\s+['"]ws['"]/.test(source), false);
  assert.equal(/require\(\s*['"]ws['"]\s*\)/.test(source), false);
});

// ---------------------------------------------------------------------------
// History projection
// ---------------------------------------------------------------------------

test('projectHistory keeps the newest entries when it truncates', () => {
  const entries = Array.from({ length: 100 }, (_value, index) => ({ id: index, text: 'x'.repeat(200) }));
  const projection = projectHistory(entries, 1024);
  assert.equal(projection.truncated, true);
  assert.ok(Buffer.byteLength(JSON.stringify(projection.entries)) <= 1024);
  assert.deepEqual(
    projection.entries.at(-1),
    entries.at(-1),
    'the newest entry must survive: a re-subscribe replays this window',
  );
  assert.ok(
    !projection.entries.includes(entries[0]),
    'the oldest entry is the one to drop',
  );
  // Order is chronological: the app appends these as later rows.
  const ids = projection.entries.map((entry) => (entry as { id: number }).id);
  assert.deepEqual(ids, [...ids].sort((a, b) => a - b));
});

test('projectHistory collapses an entry too large to ever fit, and keeps walking', () => {
  const huge = { id: 'huge', text: 'x'.repeat(4096) };
  const entries = [{ id: 'old' }, huge, { id: 'new' }];
  const projection = projectHistory(entries, 2048);
  assert.equal(
    projection.truncated,
    false,
    'the giant is collapsed, not dropped, so no older entry is omitted',
  );
  assert.deepEqual(projection.entries[0], { id: 'old' });
  assert.deepEqual(projection.entries[1], {
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(huge)),
  });
  assert.deepEqual(projection.entries[2], { id: 'new' });
  assert.ok(Buffer.byteLength(JSON.stringify(projection.entries)) <= 2048);
});

test('projectHistory collapses a giant even when it is the newest entry', () => {
  const huge = { id: 'huge', text: 'x'.repeat(4096) };
  const projection = projectHistory([{ id: 'old' }, huge], 2048);
  assert.equal(projection.truncated, false);
  assert.deepEqual(projection.entries, [
    { id: 'old' },
    { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) },
  ]);

  // Only the giant: the window may then hold exactly one marker, and the
  // comma term must not be charged for it.
  const alone = projectHistory([huge], 2048);
  assert.deepEqual(alone, {
    entries: [{ truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) }],
    truncated: false,
  });
});

test('projectHistory truncates at the byte cap and flags it', () => {
  const entries = Array.from({ length: 100 }, (_value, index) => ({ id: index, text: 'x'.repeat(200) }));
  const projection = projectHistory(entries, 1024);
  assert.equal(projection.truncated, true);
  assert.ok(Buffer.byteLength(JSON.stringify(projection.entries)) <= 1024);
  assert.ok(projection.entries.length < entries.length);
});

test('projectHistory keeps everything under the cap', () => {
  const entries = [{ id: 1 }, { id: 2 }];
  const projection = projectHistory(entries, 1024);
  assert.deepEqual(projection, { entries, truncated: false });
});

// ---------------------------------------------------------------------------
// Endpoint discovery
// ---------------------------------------------------------------------------

test('readEndpoint reads the agent port from discovery and the token from config', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-rt-'));
  const configDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-cfg-'));
  try {
    writeDiscovery(runtimeDir, {
      agentPort: 4321,
      viewerPort: 8787,
      pid: process.pid,
      startedAt: new Date().toISOString(),
      protocolVersion: PROTOCOL_VERSION,
    });
    const { token } = loadOrCreateToken(configDir);
    assert.deepEqual(readEndpoint({ runtimeDir, configDir }), {
      url: 'ws://127.0.0.1:4321',
      token,
    });
  } finally {
    rmSync(runtimeDir, { recursive: true, force: true });
    rmSync(configDir, { recursive: true, force: true });
  }
});

test('readEndpoint reports no hub when there is no discovery file', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-rt-'));
  const configDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-cfg-'));
  try {
    assert.equal(readEndpoint({ runtimeDir, configDir }), null);
  } finally {
    rmSync(runtimeDir, { recursive: true, force: true });
    rmSync(configDir, { recursive: true, force: true });
  }
});
