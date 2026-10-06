// prompts, steer, followup, images and delivery mode.
// Split from the bridge test file; test blocks are byte-exact (see .pi/plans/pc-test-split).
//
// Preserved from the original bridge test file:
//
// ---------------------------------------------------------------------------
// Command dispatch
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { test, beforeEach } from 'node:test';
import { PROTOCOL_VERSION } from '../src/protocol/protocol.ts';
import { resetSessionLinkageForTests } from './pi-droid-bridge.ts';
import { makeHarness, parsed, sendCommand } from '../test/support/bridge-harness.ts';

beforeEach(() => resetSessionLinkageForTests());

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
