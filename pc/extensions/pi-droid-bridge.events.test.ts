// message, stream and agent-state events.
// Split from the bridge test file; test blocks are byte-exact.
//
// Preserved from the original bridge test file:
//
// ---------------------------------------------------------------------------
// Agent state
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { test, beforeEach } from 'node:test';
import { MAX_RELAY_BYTES } from '../src/protocol/protocol.ts';
import type { AssistantMessageEvent } from '../src/bridge/pi-types.ts';
import { resetSessionLinkageForTests } from './pi-droid-bridge.ts';
import { imagePart, makeHarness, parsed, sampleAssistantEvent } from '../test/support/bridge-harness.ts';

beforeEach(() => resetSessionLinkageForTests());

test('an oversized toolResult message_end still emits its bounded tool frame alongside the trimmed message', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  const image = imagePart(MAX_RELAY_BYTES + 1);
  const original = {
    role: 'toolResult',
    toolCallId: 'call-1',
    toolName: 'read',
    content: [{ type: 'text', text: 'file body' }, image],
    isError: false,
  };
  harness.pi.handlers.get('message_end')!({ type: 'message_end', message: original }, harness.startCtx);
  const frames = parsed(socket).slice(before);
  const messageFrame = frames.find((m) => (m.payload as { kind?: string })?.kind === 'message');
  assert.ok(messageFrame, 'the trimmed message must be relayed');
  const payload = messageFrame.payload as { message: { role?: string; content?: unknown[] } };
  assert.equal(payload.message.role, 'toolResult');
  assert.deepEqual(payload.message.content?.[0], { type: 'text', text: 'file body' });
  assert.deepEqual(payload.message.content?.[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(image)),
  });
  // The tool frame is built from the ORIGINAL message (onMessageEnd's
  // `original`), never the trimmed payload; it has its own bound and an image
  // read degrades to a generic view, so it stays small.
  const toolFrame = frames.find((m) => (m.payload as { kind?: string })?.kind === 'tool');
  assert.ok(toolFrame, 'the tool frame must still be emitted');
  assert.equal((toolFrame.payload as { toolCallId?: string }).toolCallId, 'call-1');
});

test('the message_end handler relays assistant, user and toolResult messages and ignores other roles', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
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
  assert.deepEqual(emitted[0].payload, { kind: 'message', message: user, truncated: false });
  assert.deepEqual(emitted[1].payload, { kind: 'message', message: assistant, truncated: false });
  assert.deepEqual(emitted[2].payload, { kind: 'message', message: toolResult, truncated: false });
});

test('consecutive text deltas get strictly increasing stream seqs', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
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

test('thinking and text deltas share one stream seq sequence', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  const update = (assistantMessageEvent: AssistantMessageEvent): void => {
    harness.pi.handlers.get('message_update')!(
      { type: 'message_update', message: {}, assistantMessageEvent },
      harness.startCtx,
    );
  };
  update(sampleAssistantEvent('thinking_start'));
  update(sampleAssistantEvent('thinking_delta'));
  // An empty delta is a shape pi-ai can produce; it must still take a seq.
  update({ type: 'thinking_delta', contentIndex: 0, delta: '', partial: {} });
  update(sampleAssistantEvent('text_delta'));
  const streams = parsed(socket)
    .slice(before)
    .filter((m) => (m.payload as { kind?: string })?.kind === 'stream')
    .map((m) => m.payload as { seq: number; text?: string; phase?: string });
  assert.deepEqual(streams, [
    { kind: 'stream', seq: 1, phase: 'thinking' },
    { kind: 'stream', seq: 2, text: 'hmm', phase: 'thinking' },
    { kind: 'stream', seq: 3, text: '', phase: 'thinking' },
    { kind: 'stream', seq: 4, text: 'hello' },
  ]);
});

test('agent_settled yields the terminal agent state', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({ type: 'agent_settled' }, harness.startCtx);
  // Settling is also a context-usage boundary, so the state frame is no longer
  // the last thing on the wire. Deliberate: the terminal state still comes first.
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(emitted[0].payload, { kind: 'agent', state: 'settled' });
  assert.deepEqual(emitted[1].payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
  assert.deepEqual(emitted[2].payload, { kind: 'settled', text: '', truncated: false });
});

test('agent_start yields the running state', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  harness.pi.handlers.get('agent_start')!({ type: 'agent_start' }, harness.startCtx);
  const last = parsed(socket).at(-1)!;
  assert.deepEqual(last.payload, { kind: 'agent', state: 'running' });
});

test('agent_end does not yield the terminal state', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
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
  const first = harness.sockets[0];
  first.open();
  harness.pi.handlers.get('agent_settled')!({ type: 'agent_settled' }, harness.startCtx);
  first.drop();
  harness.fireTimer();
  const second = harness.sockets[1];
  second.open();
  const messages = parsed(second);
  assert.equal(messages[1].type, 'register');
  assert.deepEqual(messages[2].payload, { kind: 'agent', state: 'settled' });
});
