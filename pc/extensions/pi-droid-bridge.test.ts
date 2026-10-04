/**
 * The pi bridge extension, driven against a stub `ExtensionAPI` and a fake
 * socket. Nothing here dials: the socket factory is injected, the clock is
 * injected, the RNG is injected, and the debug sink is injected.
 *
 * This is the entry remainder — the Bridge class itself: lifecycle, command
 * dispatch, registration and labels, transport and endpoint discovery, and the
 * live wiring that needs a whole bridge instance. The pure-logic tests live
 * beside the module they exercise under `src/bridge/`, sharing the fakes in
 * `test/support/bridge-harness.ts`.
 *
 * The tests here are grouped by behaviour:
 * - agent state is terminal on `agent_settled`, never on `agent_end`
 * - the command allowlist dispatches, everything else is refused
 * - mode guard, silence, and lifecycle
 * - session labels, replacement, and session control
 * - live wiring, argument retention, and history replay
 */

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, beforeEach } from 'node:test';

import {
  HISTORY_MAX_BYTES,
  MAX_RELAY_BYTES,
  PROTOCOL_VERSION,
  type ToolPayload,
} from '../src/protocol/protocol.ts';
import { writeDiscovery } from '../src/hub/discovery.ts';
import { loadOrCreateToken } from '../src/hub/auth.ts';
import type { AssistantMessageEvent, BridgeModel } from '../src/bridge/pi-types.ts';
import { SESSION_COMMAND_NAME } from '../src/bridge/commands.ts';
import { readEndpoint, resetSessionLinkageForTests } from './pi-droid-bridge.ts';
import {
  StubCommandCtx,
  imagePart,
  makeCtx,
  makeHarness,
  parsed,
  sampleAssistantEvent,
  sendCommand,
} from '../test/support/bridge-harness.ts';

// The module-level predecessor survives across bridge instances by design, so a
// unit test must not inherit a linkage recorded by an earlier one.
beforeEach(() => resetSessionLinkageForTests());

test('an oversized toolResult message_end still emits its bounded tool frame alongside the trimmed message', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
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

test('thinking and text deltas share one stream seq sequence', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
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

// ---------------------------------------------------------------------------
// Agent state
// ---------------------------------------------------------------------------

test('agent_settled yields the terminal agent state', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({ type: 'agent_settled' }, harness.startCtx);
  // Settling is also a context-usage boundary, so the state frame is no longer
  // the last thing on the wire. Deliberate: the terminal state still comes first.
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(emitted[0]!.payload, { kind: 'agent', state: 'settled' });
  assert.deepEqual(emitted[1]!.payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
  assert.deepEqual(emitted[2]!.payload, { kind: 'settled', text: '', truncated: false });
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

test('prompt asks pi to expand commands and templates instead of injecting text verbatim', async () => {
  const harness = makeHarness();
  // Documentation of intent, not a witness: `makeCtx` already defaults idle to
  // true, so this line cannot fail if the idle branch is absent.
  const ctx = harness.start();
  ctx.setIdle(true);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: '/implement-vetted' });
  // pi's extension API defaults `expandPromptTemplates` to false, which hands a
  // `/name` to the model as prose instead of running the command. The bridge
  // must opt in; which commands exist is pi's business, not the bridge's.
  assert.deepEqual(harness.pi.userMessages, [
    { content: '/implement-vetted', options: { expandPromptTemplates: true } },
  ]);
});

test('steer injects the text with deliverAs steer', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'steer', { text: 'hi' });
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'hi', options: { expandPromptTemplates: true, deliverAs: 'steer' } },
  ]);
});

test('followup injects the text with deliverAs followUp', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'followup', { text: 'hi' });
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'hi', options: { expandPromptTemplates: true, deliverAs: 'followUp' } },
  ]);
});

test('a prompt while the agent is streaming is queued as a steer', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'change direction' });
  // A plain `prompt` sent mid-turn is silently dropped by pi — the reply the
  // app waits on is `ok:true` either way. `steer` queues it instead.
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'change direction', options: { expandPromptTemplates: true, deliverAs: 'steer' } },
  ]);
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: true,
    queued: true,
  });
});

test('the prompt delivery mode is read per dispatch, not once at session start', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  ctx.setIdle(false);
  await sendCommand(harness.pi, socket, 'prompt', { text: 'a' });
  ctx.setIdle(true);
  await sendCommand(harness.pi, socket, 'prompt', { text: 'b' });
  // The mode follows the current turn, not a value cached at session start.
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'a', options: { expandPromptTemplates: true, deliverAs: 'steer' } },
    { content: 'b', options: { expandPromptTemplates: true } },
  ]);
});

test('an explicit steer ignores the agent idle state', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  ctx.setIdle(true);
  await sendCommand(harness.pi, socket, 'steer', { text: 's1' });
  ctx.setIdle(false);
  await sendCommand(harness.pi, socket, 'steer', { text: 's2' });
  // `steer` says what it means: idle is irrelevant, both are steers.
  assert.deepEqual(harness.pi.userMessages, [
    { content: 's1', options: { expandPromptTemplates: true, deliverAs: 'steer' } },
    { content: 's2', options: { expandPromptTemplates: true, deliverAs: 'steer' } },
  ]);
});

test('an explicit followup ignores the agent idle state', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  ctx.setIdle(false);
  await sendCommand(harness.pi, socket, 'followup', { text: 'f1' });
  ctx.setIdle(true);
  await sendCommand(harness.pi, socket, 'followup', { text: 'f2' });
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'f1', options: { expandPromptTemplates: true, deliverAs: 'followUp' } },
    { content: 'f2', options: { expandPromptTemplates: true, deliverAs: 'followUp' } },
  ]);
});

test('a prompt with images maps them to pi content parts after the text', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', {
    text: 'look',
    images: [{ data: 'AA', mimeType: 'image/jpeg' }],
  });
  // pi's `sendUserMessage` splits a content array into text + images and hands
  // them to `prompt`; the text part must come first so a caption is never lost.
  assert.deepEqual(harness.pi.userMessages, [
    {
      content: [
        { type: 'text', text: 'look' },
        { type: 'image', data: 'AA', mimeType: 'image/jpeg' },
      ],
      options: { expandPromptTemplates: true },
    },
  ]);
});

test('a non-array images value is refused as malformed images', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'x', images: 'nope' });
  // A malformed frame must fail loudly rather than send a text-only prompt the
  // app believes carried a picture.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'malformed images',
  });
  assert.deepEqual(harness.pi.userMessages, []);
});

test('an image part with a missing mimeType is refused as malformed images', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'x', images: [{ data: 'AA' }] });
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'malformed images',
  });
  assert.deepEqual(harness.pi.userMessages, []);
});

test('an image part with an empty mimeType is refused as malformed images', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', {
    text: 'x',
    images: [{ data: 'AA', mimeType: '' }],
  });
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'malformed images',
  });
  assert.deepEqual(harness.pi.userMessages, []);
});

test('an empty images array is treated as absent', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'x', images: [] });
  // The app may send an empty list; it must not make the content an array with
  // an empty image tail.
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'x', options: { expandPromptTemplates: true } },
  ]);
});

test('images without text are refused as missing text before parsing images', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', {
    images: [{ data: 'AA', mimeType: 'image/jpeg' }],
  });
  // The text check comes first: an image cannot be sent alone, and the refusal
  // names the missing caption rather than the images.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'missing text',
  });
  assert.deepEqual(harness.pi.userMessages, []);
});

test('an isIdle() that throws fails the command loudly instead of crashing', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdleError(new Error('runner is not active'));
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'x' });
  // A pi lacking `isIdle` throws here. The failure must surface as a loud
  // `ok:false` on the reply the app already awaits — not an escaped rejection,
  // and not the silent drop this change exists to fix.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'runner is not active',
  });
});

test('an idle prompt reply carries no queued flag', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(true);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'now' });
  // Only a steer chose to queue. An idle prompt is dispatched exactly as
  // before, so its reply must stay the frame an older app already understands.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: true,
  });
});

test('an explicit steer reply carries no queued flag', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'steer', { text: 's' });
  // `steer` names its mode; it is not the bridge deciding to queue a plain
  // prompt mid-turn, so it must not claim the queued signal.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-steer',
    ok: true,
  });
});

test('an explicit followup reply carries no queued flag', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'followup', { text: 'f' });
  // `followup` names its mode too — it forces `followUp` regardless of idle,
  // so, like `steer`, it must not claim the queued signal.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-followup',
    ok: true,
  });
});

test('a refused prompt reply carries no queued flag', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', {});
  // A refusal is not a queue: `ok:false` must stand alone, with no queued hint
  // the app could render as success.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'missing text',
  });
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

test('setModel resolves the reference through the registry before calling pi', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  // The resolved registry OBJECT, not the `{provider, id}` reference: pi's
  // setModel needs the full Model, and passing the reference would be a
  // type-lie pi cannot use.
  assert.deepEqual(harness.pi.models, [
    { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  ]);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
});

test('setModel reports a rejected model as a failed command-result', async () => {
  const harness = makeHarness();
  harness.pi.modelAccepted = false;
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // The wrapper's `false` path (a stale auth snapshot), distinct from the
  // unknown-id `'model not found'` and the no-registry `'models unavailable'`.
  assert.equal(result.error, 'model not accepted');
});

test('setModel refuses an unknown model without calling pi', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { provider: 'test-provider', id: 'nope' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'model not found');
  assert.deepEqual(harness.pi.models, [], 'pi.setModel must not be called for an unknown model');
});

test('setModel without a provider or id is refused', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { id: 'test-model' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'missing model');
  assert.deepEqual(harness.pi.models, []);
});

test('setModel without a registry is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.removeRegistry();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { provider: 'test-provider', id: 'test-model' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'models unavailable');
  assert.deepEqual(harness.pi.models, []);
});

test('setModel is refused mid-turn, before calling pi', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { provider: 'test-provider', id: 'test-model' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'cannot switch the model while pi is working');
  // pi's own AgentSession.setModel has no streaming guard; the bridge refuses
  // before the switch so the session cannot end up on a mixed-model turn.
  assert.deepEqual(harness.pi.models, [], 'pi.setModel must not be called mid-turn');
});

test('a throwing pi.setModel surfaces the thrown message, not the accepted boolean', async () => {
  const harness = makeHarness();
  harness.pi.modelError = new Error('No API key for test-provider/test-model');
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // A stale auth snapshot makes pi's inner setModel THROW; the message must
  // survive rather than be replaced by the wrapper's `'model not accepted'`.
  assert.equal(result.error, 'No API key for test-provider/test-model');
});

test('an accepted same-model switch still re-reports usage exactly once', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  // `_emitModelSelect` early-returns for an equal model, so the direct
  // `sendUsageEvent` is the only frame and must not be dropped.
  // The exact count pins StubPi's behaviour (its `setModel` never emits
  // `model_select`), not a wire guarantee: real pi also emits the event, which
  // the bridge documents as a harmless idempotent duplicate. If the stub grows
  // faithful, relax the count to >= 1 — do not "fix" the bridge.
  const usage = parsed(socket)
    .slice(before)
    .filter((message) => (message.payload as { kind?: string } | undefined)?.kind === 'usage');
  assert.equal(usage.length, 1);
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

test('a history-request replays history and then the context usage', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  const after = parsed(socket).slice(-2);
  assert.equal(after[0]!.type, 'history');
  // A phone that attaches mid-session must see a number without waiting for a
  // turn, and the hub only relays to subscribers — which is why this rides the
  // reply rather than the register frame.
  assert.deepEqual(after[1], {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: {
      kind: 'usage',
      tokens: 23400,
      contextWindow: 128000,
      thinkingLevel: 'medium',
      model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
    },
  });
});

test('an unknown token count travels as null', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setUsage({ tokens: null, contextWindow: 128000 });
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: null,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('agent_settled reports the terminal state and then the usage', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(
    emitted.map((m) => (m.payload as { kind?: string }).kind),
    ['agent', 'usage', 'settled'],
  );
});

test('a compaction reports unknown tokens', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  ctx.setUsage({ tokens: null, contextWindow: 128000 });
  harness.pi.handlers.get('session_compact')!({}, ctx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual((emitted.at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: null,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('a context without a thinking level omits the field', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete ctx.thinkingLevel;
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  // The key must be absent, not `null`: an older pi exposes no level and the
  // field is optional.
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('a context without a model omits the field', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete ctx.model;
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  // The key must be absent, not `null`: an older pi exposes no model and the
  // field is optional.
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
  });
});

test('a malformed model is omitted, never sent half-formed', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // `name` missing: the projection must drop the whole entry rather than emit a
  // `ModelSummary` the protocol validator would reject.
  ctx.model = { id: 'test-model', provider: 'test-provider' } as unknown as BridgeModel;
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
  });
});

test('a model_select re-reports usage', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  ctx.model = { id: 'm2', provider: 'test-provider', name: 'Second Model' };
  harness.pi.handlers.get('model_select')!(
    { model: ctx.model, previousModel: undefined, source: 'select' },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'm2', name: 'Second Model' },
  });
});

test('a thinking level change re-reports usage', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  ctx.thinkingLevel = 'low';
  harness.pi.handlers.get('thinking_level_select')!(
    { level: 'low', previousLevel: 'medium' },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'low',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('the reported thinking level is read live, not cached', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  ctx.thinkingLevel = 'high';
  const before = socket.sent.length;
  harness.pi.handlers.get('thinking_level_select')!(
    { level: 'high', previousLevel: 'low' },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'high',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('a failed compaction reaches the transcript as an error notice', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!(
    { reason: 'manual', errorMessage: 'Compaction failed: no model', aborted: false },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'status',
    event: 'error',
    message: 'Compaction failed: no model',
  });
});

test('an overflow compaction failure also reaches the transcript', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!(
    {
      reason: 'overflow',
      errorMessage: 'Context overflow recovery failed: too large',
      aborted: false,
    },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'status',
    event: 'error',
    message: 'Context overflow recovery failed: too large',
  });
});

test('an aborted compaction clears the announcement without an error notice', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!({ reason: 'manual', aborted: true }, ctx);
  // The announcement must still be cleared — an aborted compaction is over just
  // like a failed one — but nothing is shown, because nothing went wrong.
  assert.deepEqual(parsed(socket).slice(before).map((m) => (m as { payload: unknown }).payload), [
    { kind: 'status', event: 'compacting', active: false },
  ]);
});

test('a compaction start announces itself to the app', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_before_compact')!(
    { type: 'session_before_compact', reason: 'manual', willRetry: false },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'status',
    event: 'compacting',
    active: true,
  });
});

test('the compaction start handler neither cancels nor customises the compaction', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  harness.sockets[0]!.open();
  // pi awaits this handler and reads the result: a truthy `cancel` aborts the
  // compaction and a `compaction` replaces the summary. Returning undefined is
  // what keeps the bridge from silently changing what compaction does.
  const result = harness.pi.handlers.get('session_before_compact')!(
    { type: 'session_before_compact', reason: 'threshold', willRetry: true },
    ctx,
  );
  assert.equal(result, undefined);
});

test('a completed compaction clears the announcement', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact')!({ type: 'session_compact', reason: 'manual' }, ctx);
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .map((m) => (m as { payload: { kind: string; event?: string } }).payload)
      .filter((p) => p.kind === 'status'),
    [{ kind: 'status', event: 'compacting', active: false }],
  );
});

test('a failed compaction clears the announcement before the error notice', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!(
    { reason: 'overflow', errorMessage: 'Context overflow recovery failed', aborted: false },
    ctx,
  );
  // Order matters: the indicator is cleared first, so the app cannot end up
  // showing "Compacting…" and a failure notice at the same time.
  assert.deepEqual(parsed(socket).slice(before).map((m) => (m as { payload: unknown }).payload), [
    { kind: 'status', event: 'compacting', active: false },
    { kind: 'status', event: 'error', message: 'Context overflow recovery failed' },
  ]);
});

test('an accepted model switch reports the new window', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setUsage({ tokens: 100, contextWindow: 200000 });
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    ['usage'],
  );
});

test('a refused model switch reports nothing about usage', async () => {
  const harness = makeHarness();
  harness.pi.modelAccepted = false;
  const ctx = harness.start();
  ctx.setUsage({ tokens: 100, contextWindow: 200000 });
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    [],
  );
});

test('a pi without getContextUsage emits no usage frame', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete ctx.getContextUsage;
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    [],
  );
  // The history reply itself must still arrive: a missing usage reading is not
  // allowed to take the transcript down with it.
  assert.ok(parsed(socket).some((m) => m.type === 'history'));
});

test('an undefined usage reading emits no usage frame', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setUsage(undefined);
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    [],
  );
});

test('a throwing getContextUsage does not escape and costs only the reading', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.getContextUsage = () => {
    throw new Error('usage exploded');
  };
  const socket = harness.sockets[0]!;
  socket.open();
  assert.doesNotThrow(() => {
    socket.message({
      protocolVersion: PROTOCOL_VERSION,
      type: 'history-request',
      sessionId: 'sess-1',
    });
  });
  assert.deepEqual(harness.writes, []);
  assert.ok(parsed(socket).some((m) => m.type === 'history'));
});

test('stream deltas never sample the context', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const update = (): void => {
    harness.pi.handlers.get('message_update')!(
      {
        type: 'message_update',
        message: {},
        assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: 'x', partial: {} },
      },
      ctx,
    );
  };
  for (let index = 0; index < 20; index += 1) update();
  // Reading it walks the whole session projection, so it is a boundary cost and
  // must never land on the delta path.
  assert.equal(ctx.usageCalls(), 0);
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.equal(ctx.usageCalls(), 1);
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

test('history-request projects the active branch, not the whole file', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // a1 is on an abandoned branch; only b1/b2 are on the active one.
  ctx.setEntries([
    { type: 'message', id: 'a1', message: { role: 'user', content: 'abandoned' } },
    { type: 'message', id: 'b1', message: { role: 'user', content: 'kept' } },
    { type: 'message', id: 'b2', message: { role: 'assistant', content: 'reply' } },
  ]);
  ctx.setBranchEntries([
    { type: 'message', id: 'b1', message: { role: 'user', content: 'kept' } },
    { type: 'message', id: 'b2', message: { role: 'assistant', content: 'reply' } },
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  const history = parsed(socket).find((m) => m.type === 'history');
  assert.ok(history, 'a history frame must be sent');
  const entries = history.entries as Array<{ id: string }>;
  assert.deepEqual(entries.map((entry) => entry.id), ['b1', 'b2']);
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

test("listCommands answers with pi's commands, dropping source and absent descriptions", async () => {
  const harness = makeHarness();
  harness.pi.commands = [
    {
      name: 'review',
      description: 'Review the working tree',
      source: 'extension',
      sourceInfo: { path: '/ext/review.md' },
    },
    { name: 'implement-vetted', source: 'prompt', sourceInfo: { path: '/prompts/implement-vetted.md' } },
  ];
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  // `source`/`sourceInfo` must not travel, and an absent description must not
  // become an empty string: the app needs a label and an optional subtitle only.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-listCommands',
    ok: true,
    commands: [
      { name: 'review', description: 'Review the working tree' },
      { name: 'implement-vetted' },
    ],
  });
});

test('a listCommands reply carries no queued flag', async () => {
  const harness = makeHarness();
  harness.pi.commands = [{ name: 'review' }];
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  // `sendCommandResult` is a shared path; only the prompt branch may set the
  // queued key, so a command result must stay exactly its own shape.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-listCommands',
    ok: true,
    commands: [{ name: 'review' }],
  });
});

test('listCommands reports failure when pi has no getCommands method', async () => {
  const harness = makeHarness();
  // Older pi: the method is absent, so the bridge's optional call must
  // short-circuit. Deleting it is what exercises `?.`; a present method that
  // returns `undefined` takes the `raw === undefined` guard instead.
  (harness.pi as { getCommands?: unknown }).getCommands = undefined;
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as {
    type: string;
    ok: boolean;
    error?: string;
    commands?: unknown;
  };
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
  // The specific reason matters: a plain allowlist refusal would also be
  // `ok:false`, so this pins the bridge's own no-list branch.
  assert.equal(result.error, 'commands unavailable');
  assert.equal(result.commands, undefined);
});

test('listCommands reports failure when getCommands returns undefined', async () => {
  const harness = makeHarness();
  harness.pi.commandsAvailable = false;
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as {
    type: string;
    ok: boolean;
    error?: string;
    commands?: unknown;
  };
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
  assert.equal(result.error, 'commands unavailable');
  assert.equal(result.commands, undefined);
});

test('listCommands preserves duplicate names in pi order', async () => {
  const harness = makeHarness();
  harness.pi.commands = [
    { name: 'review', description: 'first' },
    { name: 'other' },
    { name: 'review', description: 'second' },
    // Malformed entries are skipped by the `continue` path, never crash the
    // loop and never reach the wire.
    null,
    42,
    'oops',
  ] as unknown as typeof harness.pi.commands;
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as {
    commands: Array<{ name: string; description?: string }>;
  };
  // Duplicates are preserved and ordered: a future dedupe must be deliberate.
  assert.deepEqual(result.commands, [
    { name: 'review', description: 'first' },
    { name: 'other' },
    { name: 'review', description: 'second' },
  ]);
});

test('listModels returns the available models projected to provider, id and name', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setAvailable([
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
    { provider: 'openai', id: 'gpt-5', name: 'GPT-5' },
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; models?: unknown };
  assert.equal(result.ok, true, `listModels was refused: ${String((result as { error?: string }).error)}`);
  assert.deepEqual(result.models, [
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
    { provider: 'openai', id: 'gpt-5', name: 'GPT-5' },
  ]);
});

test('listModels drops an entry missing provider, id or name', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setAvailable([
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
    { provider: 'anthropic', name: 'no id' },
    { id: 'no-provider', name: 'N' },
    { provider: 'p', id: 'm' },
    null,
    42,
    'oops',
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { models?: unknown };
  assert.deepEqual(result.models, [
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
  ]);
});

test('listModels never lets a credential or extra model field reach the wire', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setAvailable([
    {
      provider: 'p',
      id: 'm',
      name: 'M',
      headers: { authorization: 'secret' },
      baseUrl: 'http://x',
      compat: { something: true },
      cost: { input: 1 },
    },
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { models?: unknown };
  // Deep equality, not a field check: an extra key would fail this too.
  assert.deepEqual(result.models, [{ provider: 'p', id: 'm', name: 'M' }]);
});

test('an older pi without a registry is refused, not reported as empty', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.removeRegistry();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string; models?: unknown };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'models unavailable');
  // `[]` would be a lie: the app must not show an empty picker as a real answer.
  assert.equal(result.models, undefined);
});

test('a registry whose getAvailable is not an array is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.modelRegistry = {
    getAvailable: () => 'nope' as unknown as unknown[],
    find: () => undefined,
  };
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'models unavailable');
});

test('a registry whose getAvailable throws reports the thrown message', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.modelRegistry = {
    getAvailable: () => {
      throw new Error('registry exploded');
    },
    find: () => undefined,
  };
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // The throw must reach `dispatch`'s catch and surface verbatim, not be
  // swallowed into a generic refusal.
  assert.equal(result.error, 'registry exploded');
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

test('install registers the internal session command', () => {
  const harness = makeHarness();
  // The bridge can only drive a session action through a real command context,
  // and a command context is reachable only from a registered command. One
  // registration, once per install.
  assert.deepEqual(
    harness.pi.registeredCommands.map((command) => command.name),
    [SESSION_COMMAND_NAME],
  );
});

test('a replacement session_start registers the id it replaced', () => {
  for (const reason of ['new', 'fork', 'resume']) {
    // Real replacement: pi re-runs the extension factory, so the successor's
    // `session_start` lands on a NEW bridge instance that knows the predecessor
    // only through the module-level value. Modelling that needs a second
    // install, not a re-fire on the same instance.
    const real = makeHarness();
    real.start('tui', 'sess-1', 'startup');
    real.sockets[0]!.open();
    real.reinstall();
    real.start('tui', 'sess-2', reason);
    const realSecond = real.sockets[1]!;
    realSecond.open();
    const realRegister = parsed(realSecond).find((m) => m.type === 'register')!;
    assert.equal(
      realRegister.replaces,
      'sess-1',
      `${reason} did not carry replaces across a real replacement`,
    );

    // Same-instance re-fire, which still pins the module-state comparison.
    const inPlace = makeHarness();
    inPlace.start('tui', 'sess-1', 'startup');
    inPlace.sockets[0]!.open();
    inPlace.start('tui', 'sess-2', reason);
    const second = inPlace.sockets[1]!;
    second.open();
    const register = parsed(second).find((m) => m.type === 'register')!;
    assert.equal(register.replaces, 'sess-1', `${reason} did not carry replaces`);
  }
});

test('resetSessionLinkageForTests clears the module-level predecessor', () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  resetSessionLinkageForTests();
  harness.start('tui', 'sess-2', 'new');
  const second = harness.sockets[1]!;
  second.open();
  const register = parsed(second).find((m) => m.type === 'register')!;
  // Without the clear, the module still names sess-1 and the successor would be
  // linked to a session a previous test registered, not this one's.
  assert.equal(register.replaces, undefined, 'the reset must clear the recorded predecessor');
});

test('a non-replacement session_start carries no replaces', () => {
  for (const reason of ['startup', 'reload']) {
    const harness = makeHarness();
    harness.start('tui', 'sess-1', 'startup');
    harness.sockets[0]!.open();
    harness.start('tui', 'sess-2', reason);
    const second = harness.sockets[1]!;
    second.open();
    const register = parsed(second).find((m) => m.type === 'register')!;
    assert.equal(register.replaces, undefined, `${reason} carried replaces`);
  }
});

test('a resume that reloads the same session id carries no replaces', () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  // `/resume` can reload the very id already registered; naming it as replaced
  // would make the app follow a successor that does not exist.
  harness.start('tui', 'sess-1', 'resume');
  const second = harness.sockets[1]!;
  second.open();
  const register = parsed(second).find((m) => m.type === 'register')!;
  assert.equal(register.replaces, undefined);
});

test('replaces survives a register that could not be sent and is cleared only after one that was', () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  harness.start('tui', 'sess-2', 'new');
  // sockets[1] is deliberately left closed, and a label refresh is the one
  // closed-socket path that calls `sendRegister`. It must not consume the
  // replacement: nothing reached the hub, so the app never saw the linkage.
  harness.pi.setSessionName('renamed while closed');
  harness.pi.handlers.get('session_info_changed')!(
    { type: 'session_info_changed' },
    harness.startCtx,
  );
  const second = harness.sockets[1]!;
  second.open();
  const registers = parsed(second).filter((m) => m.type === 'register');
  assert.equal(registers.length, 1);
  assert.equal(registers[0]!.replaces, 'sess-1');
  // A second rename now reaches the open socket, so the flag is consumed and the
  // next register omits it — it must not link a third, later register.
  harness.pi.setSessionName('renamed while open');
  harness.pi.handlers.get('session_info_changed')!(
    { type: 'session_info_changed' },
    harness.startCtx,
  );
  const after = parsed(second).filter((m) => m.type === 'register');
  assert.equal(after.length, 2);
  assert.equal(after[1]!.replaces, undefined);
});

test('sessionNew acknowledges and triggers the registered command', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionNew');
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
  // The only route to a command context is a real command invocation, so the
  // bridge triggers its own registered command rather than calling pi directly.
  assert.deepEqual(
    harness.pi.userMessages.map((message) => message.content),
    [`/${SESSION_COMMAND_NAME} new`],
  );
});

test('the registered handler for new calls newSession exactly once and returns', async () => {
  const harness = makeHarness();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  await handler('new', cmdCtx);
  // The stub throws on a second call, modelling pi's `assertActive`: a handler
  // that touched the context again after `newSession` would blow up here.
  assert.deepEqual(cmdCtx.calls, ['newSession']);
});

test('a cancelled newSession emits an error status instead of a silent ack', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  cmdCtx.setCancel(true);
  await handler('new', cmdCtx);
  // pi resolves `{cancelled:true}` when a `session_before_switch` handler
  // cancels. Without this notice the app would wait on a replacement that will
  // never come.
  const status = parsed(socket).find(
    (message) =>
      message.type === 'event' && (message.payload as { kind?: string }).kind === 'status',
  );
  assert.ok(status, 'a cancelled replacement emitted no status');
  assert.equal((status.payload as { event?: string }).event, 'error');
});

test('a navigateTree failure emits an error status', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  cmdCtx.setThrow(new Error('cannot navigate'));
  await handler('tree t9', cmdCtx);
  // `navigateTree` throws on a streaming/compacting session or an unknown id.
  // The throw must become a notice, never an unhandled rejection inside pi.
  const status = parsed(socket).find(
    (message) =>
      message.type === 'event' && (message.payload as { kind?: string }).kind === 'status',
  );
  assert.ok(status, 'a throwing tree navigation emitted no status');
  assert.equal((status.payload as { event?: string }).event, 'error');
  assert.match((status.payload as { message?: string }).message ?? '', /cannot navigate/);
});

test('an unknown session action emits an error status instead of a silent ack', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  // `dispatch` has already acked `ok:true`; a mistyped action must not fall off
  // the end of the handler silently.
  await handler('bogus t1', new StubCommandCtx());
  const status = parsed(socket).find(
    (message) =>
      message.type === 'event' && (message.payload as { kind?: string }).kind === 'status',
  );
  assert.ok(status, 'an unknown action emitted no status');
  assert.equal((status.payload as { event?: string }).event, 'error');
  assert.equal(
    (status.payload as { message?: string }).message,
    'unknown session action: bogus',
  );
  // An empty action names itself too, rather than printing nothing.
  await handler('', new StubCommandCtx());
  const last = parsed(socket).at(-1) as { payload?: { message?: string } };
  assert.equal(last.payload?.message, 'unknown session action: (empty)');
});

test('sessionTree refuses while pi is working', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionTree', { entryId: 't1' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // The specific reason, not the generic allowlist refusal: `navigateTree`
  // throws mid-stream, so the bridge refuses before triggering the command.
  assert.equal(result.error, 'cannot navigate the tree while pi is working');
  assert.deepEqual(harness.pi.userMessages, []);
});

test('a session_tree event emits a leaf event with the new leaf', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const handler = harness.pi.handlers.get('session_tree');
  assert.ok(handler, 'the bridge must subscribe to pi\'s session_tree event');
  handler!({ type: 'session_tree', newLeafId: 'e9', oldLeafId: 'e1' }, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(emitted.at(-1)?.payload, { kind: 'leaf', leafId: 'e9' });
});

test('a session_tree to the root emits leafId null', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const handler = harness.pi.handlers.get('session_tree');
  assert.ok(handler, 'the bridge must subscribe to pi\'s session_tree event');
  handler!({ type: 'session_tree', newLeafId: null, oldLeafId: 'e1' }, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(emitted.at(-1)?.payload, { kind: 'leaf', leafId: null });
});

test('sessionTree refuses an entry id pi does not know', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // The id was listed earlier but the entry is gone now: pi's navigateTree
  // would throw after the ack, so the refusal must happen at dispatch.
  ctx.setEntries([{ type: 'message', id: 'e1', message: { role: 'user', content: 'hi' } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionTree', { entryId: 'gone' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'unknown entry');
  // Refused before the command is ever triggered.
  assert.deepEqual(harness.pi.userMessages, []);
});

test('sessionFork rejects a non-user entry', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // Forking with the default `before` position requires a user message entry;
  // an assistant entry is not a valid fork target.
  ctx.setEntries([{ type: 'message', id: 'e9', message: { role: 'assistant', content: [] } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionFork', { entryId: 'e9' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'unknown entry');
  // Refused before the command is ever triggered.
  assert.deepEqual(harness.pi.userMessages, []);
});

test('sessionFork rejects a non-message entry that carries a user message', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // A non-message variant that happens to carry a `message` object must not
  // pass the role check: it would only fail later, after `ok:true` was acked.
  ctx.setEntries([{ type: 'compaction', id: 'c9', message: { role: 'user', content: 'x' } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionFork', { entryId: 'c9' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'unknown entry');
  assert.deepEqual(harness.pi.userMessages, []);
});

test('a sessionFork for a user entry triggers the fork with the entry id', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setEntries([{ type: 'message', id: 'e3', message: { role: 'user', content: 'hi' } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionFork', { entryId: 'e3' });
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
  assert.deepEqual(
    harness.pi.userMessages.map((message) => message.content),
    [`/${SESSION_COMMAND_NAME} fork e3`],
  );
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  await handler('fork e3', cmdCtx);
  assert.deepEqual(cmdCtx.calls, ['fork']);
});

test('after a session switch the previous session id is refused as a mismatch', async () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  const secondCtx = harness.start('tui', 'sess-2', 'startup');
  const secondSocket = harness.sockets[1]!;
  secondSocket.open();
  // A stale id from before the replacement must not be dispatched against the
  // successor context. `sendCommand` hardcodes `sess-1`, which is exactly the
  // stale id under test.
  await sendCommand(harness.pi, secondSocket, 'abort');
  const result = parsed(secondSocket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'session mismatch');
  assert.equal(secondCtx.aborts(), 0);
  assert.equal(secondCtx.compacts(), 0);
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

// ---------------------------------------------------------------------------
// Live wiring and history replay
// ---------------------------------------------------------------------------

test('a message_end emits its tool frames after the message, in order', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    {
      type: 'message_end',
      message: {
        role: 'assistant',
        content: [{ type: 'toolCall', id: 'call-1', name: 'bash', arguments: { command: 'echo hi' } }],
      },
    },
    harness.startCtx,
  );
  handler(
    {
      type: 'message_end',
      message: {
        role: 'toolResult',
        toolCallId: 'call-1',
        toolName: 'bash',
        content: [{ type: 'text', text: 'hi\n' }],
        isError: false,
      },
    },
    harness.startCtx,
  );
  const frames = parsed(socket).slice(before).map((m) => m.payload as ToolPayload);
  assert.deepEqual(
    frames.map((frame) => frame.kind),
    ['message', 'tool', 'message', 'tool'],
  );
  assert.equal(frames[1]!.status, 'running');
  assert.equal(frames[1]!.name, 'bash');
  assert.deepEqual(frames[1]!.view, { type: 'generic', target: 'echo hi' });
  assert.equal(frames[3]!.status, 'done');
  assert.deepEqual(frames[3]!.view, {
    type: 'command',
    command: 'echo hi',
    output: 'hi\n',
    exitCode: 0,
  });
});

test('a resumed session resolves a toolResult from entries seeded at session_start', () => {
  const harness = makeHarness();
  const ctx = makeCtx();
  ctx.setEntries([
    {
      type: 'message',
      message: {
        role: 'assistant',
        content: [{ type: 'toolCall', id: 'call-9', name: 'read', arguments: { path: 'seeded.ts' } }],
      },
    },
  ]);
  harness.pi.handlers.get('session_start')!({ type: 'session_start', reason: 'startup' }, ctx);
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('message_end')!(
    {
      type: 'message_end',
      message: {
        role: 'toolResult',
        toolCallId: 'call-9',
        toolName: 'read',
        content: [{ type: 'text', text: 'body' }],
        isError: false,
      },
    },
    ctx,
  );
  const tool = parsed(socket)
    .slice(before)
    .map((m) => m.payload as ToolPayload)
    .find((payload) => payload?.kind === 'tool')!;
  assert.deepEqual(tool.view, { type: 'file', path: 'seeded.ts', content: 'body' });
});

test('a completed call in the entries is not seeded (its later result renders without arguments)', () => {
  const harness = makeHarness();
  const ctx = makeCtx();
  ctx.setEntries([
    {
      type: 'message',
      message: {
        role: 'assistant',
        content: [
          { type: 'toolCall', id: 'call-9', name: 'write',
            arguments: { path: 'done.ts', content: 'SENTINEL' } },
        ],
      },
    },
    {
      type: 'message',
      message: {
        role: 'toolResult', toolCallId: 'call-9', toolName: 'write',
        content: [{ type: 'text', text: 'wrote done.ts' }], isError: false,
      },
    },
  ]);
  harness.pi.handlers.get('session_start')!({ type: 'session_start', reason: 'reload' }, ctx);
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('message_end')!(
    {
      type: 'message_end',
      message: {
        role: 'toolResult', toolCallId: 'call-9', toolName: 'write',
        content: [{ type: 'text', text: 'wrote done.ts' }], isError: false,
      },
    },
    ctx,
  );
  const tool = parsed(socket).slice(before).map((m) => m.payload as ToolPayload)
    .find((payload) => payload?.kind === 'tool')!;
  assert.ok(tool);
  assert.equal(tool.status, 'done');
  assert.deepEqual(tool.view, { type: 'generic' });
});

test('a live call’s arguments are released once its result has been emitted', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    {
      type: 'message_end',
      message: {
        role: 'assistant',
        content: [{ type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'a.ts' } }],
      },
    },
    harness.startCtx,
  );
  handler(
    {
      type: 'message_end',
      message: {
        role: 'toolResult', toolCallId: 'call-1', toolName: 'read',
        content: [{ type: 'text', text: 'body' }], isError: false,
      },
    },
    harness.startCtx,
  );
  const first = parsed(socket).map((m) => m.payload as ToolPayload)
    .filter((payload) => payload?.kind === 'tool' && payload.status === 'done').pop()!;
  assert.deepEqual(first.view, { type: 'file', path: 'a.ts', content: 'body' },
    'the result is paired while the call is still held');
  const before = socket.sent.length;
  // A second result for the same id is the only public observable of the release:
  // a call whose arguments are gone renders with empty args.
  handler(
    {
      type: 'message_end',
      message: {
        role: 'toolResult', toolCallId: 'call-1', toolName: 'read',
        content: [{ type: 'text', text: 'body' }], isError: false,
      },
    },
    harness.startCtx,
  );
  const second = parsed(socket).slice(before).map((m) => m.payload as ToolPayload)
    .find((payload) => payload?.kind === 'tool')!;
  assert.deepEqual(second.view, { type: 'file', path: '', content: 'body' });
});

test('a settled turn releases a call that never produced a result', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    {
      type: 'message_end',
      message: {
        role: 'assistant',
        content: [{ type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'a.ts' } }],
      },
    },
    harness.startCtx,
  );
  harness.pi.handlers.get('agent_settled')!({ type: 'agent_settled' }, harness.startCtx);
  const before = socket.sent.length;
  handler(
    {
      type: 'message_end',
      message: {
        role: 'toolResult', toolCallId: 'call-1', toolName: 'read',
        content: [{ type: 'text', text: 'late' }], isError: false,
      },
    },
    harness.startCtx,
  );
  const tool = parsed(socket).slice(before).map((m) => m.payload as ToolPayload)
    .find((payload) => payload?.kind === 'tool')!;
  assert.deepEqual(tool.view, { type: 'file', path: '', content: 'late' });
});

test('fetchHistory replays a history whose entries carry the synthesized tool frames', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setEntries([
    {
      type: 'message',
      message: {
        role: 'assistant',
        content: [{ type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'a.ts' } }],
      },
    },
    {
      type: 'message',
      message: {
        role: 'toolResult',
        toolCallId: 'call-1',
        toolName: 'read',
        content: [{ type: 'text', text: 'body' }],
        isError: false,
      },
    },
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'fetchHistory');
  const history = parsed(socket).find((m) => m.type === 'history')!;
  const entries = history.entries as Array<Record<string, unknown>>;
  const tools = entries.filter((entry) => entry.kind === 'tool');
  assert.deepEqual(tools.map((tool) => tool.status), ['running', 'done']);
  assert.ok(Buffer.byteLength(JSON.stringify(entries)) <= HISTORY_MAX_BYTES);
});

test('a tool-heavy history keeps the newest turns within HISTORY_MAX_BYTES', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const body = 'z'.repeat(4000);
  const entries: unknown[] = [];
  for (let index = 0; index < 250; index += 1) {
    entries.push({
      type: 'message',
      message: {
        role: 'assistant',
        content: [
          { type: 'toolCall', id: `call-${index}`, name: 'read', arguments: { path: `f${index}.txt` } },
        ],
      },
    });
    entries.push({
      type: 'message',
      message: {
        role: 'toolResult',
        toolCallId: `call-${index}`,
        toolName: 'read',
        content: [{ type: 'text', text: body }],
        isError: false,
      },
    });
  }
  ctx.setEntries(entries);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'fetchHistory');
  const history = parsed(socket).find((m) => m.type === 'history')!;
  const kept = history.entries as Array<Record<string, unknown>>;
  assert.ok(Buffer.byteLength(JSON.stringify(kept)) <= HISTORY_MAX_BYTES);
  assert.equal(history.truncated, true, 'a 250-pair tool-heavy session must not fit the window');
  const doneFrames = kept.filter((entry) => entry.kind === 'tool' && entry.status === 'done');
  assert.ok(doneFrames.length > 0, 'the newest turn tools must survive');
  assert.equal(doneFrames.at(-1)!.toolCallId, 'call-249');
});
