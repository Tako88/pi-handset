/**
 * Session label derivation and the settled-text snippet, exercised through
 * `src/bridge/labels.ts`.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { MAX_RELAY_BYTES } from '../protocol/protocol.ts';
import { settleText, SETTLED_TEXT_MAX_CODE_POINTS } from './labels.ts';
import {
  makeHarness,
  parsed,
  sendCommand,
  type FakeSocket,
} from '../../test/support/bridge-harness.ts';

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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, '😀'.repeat(80));
  assert.equal(Array.from(register.name).length, 80);
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.ok(register);
  assert.equal('name' in register, false);
});

test('a new user prompt re-registers with the new label', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  assert.equal(parsed(socket).filter((m) => m.type === 'register').length, 1);
  harness.pi.handlers.get('message_end')!(
    { type: 'message_end', message: { role: 'user', content: 'new topic' } },
    harness.startCtx,
  );
  const registers = parsed(socket).filter((m) => m.type === 'register');
  assert.equal(registers.length, 2);
  assert.equal(registers[1].name, 'new topic');
});

test('a repeated prompt with the same text does not re-register', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
  socket.open();
  await sendCommand(harness.pi, socket, 'setSessionName', { name: 'Phone chat' });
  const registers = parsed(socket).filter((m) => m.type === 'register');
  assert.equal(registers.length, 2);
  assert.equal(registers[1].name, 'Phone chat');
});

test('a throwing getEntries during register still sends the register frame', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  (harness.pi as { getSessionName?: unknown }).getSessionName = undefined;
  ctx.sessionManager.getEntries = () => {
    throw new Error('entries exploded');
  };
  const socket = harness.sockets[0];
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.ok(register);
  assert.equal('name' in register, false);
});

test('a session_info_changed event from a TUI rename re-registers', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  harness.pi.setSessionName('tui rename');
  harness.pi.handlers.get('session_info_changed')!(
    { type: 'session_info_changed', name: 'tui rename' },
    harness.startCtx,
  );
  const registers = parsed(socket).filter((m) => m.type === 'register');
  assert.equal(registers.length, 2);
  assert.equal(registers[1].name, 'tui rename');
});

// ---------------------------------------------------------------------------
// Settle snippet (the notification body)
// ---------------------------------------------------------------------------

/** The last `settled` payload in a socket's sent frames, if any. */
function settlePayload(
  socket: FakeSocket,
  from = 0,
): { kind: string; text: string; truncated: boolean } | undefined {
  return parsed(socket)
    .slice(from)
    .map((message) => message.payload as { kind?: string })
    .filter((payload) => payload?.kind === 'settled')
    .at(-1) as { kind: string; text: string; truncated: boolean } | undefined;
}

test('settleText keeps text at the cap and flags one code point over', () => {
  assert.deepEqual(settleText('abc', 3), { text: 'abc', truncated: false });
  assert.deepEqual(settleText('abcd', 3), { text: 'abc', truncated: true });
});

test('agent_settled emits the assistant text cached from message_end', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  harness.pi.handlers.get('message_end')!(
    { type: 'message_end', message: { role: 'assistant', content: 'the answer' } },
    harness.startCtx,
  );
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(
    emitted.map((m) => (m.payload as { kind?: string }).kind),
    ['agent', 'usage', 'settled'],
  );
  assert.deepEqual(emitted[2].payload, {
    kind: 'settled',
    text: 'the answer',
    truncated: false,
  });
});

test('an oversized assistant message_end still yields its text, flagged truncated', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const huge = { role: 'assistant', content: 'x'.repeat(MAX_RELAY_BYTES + 100) };
  harness.pi.handlers.get('message_end')!(
    { type: 'message_end', message: huge },
    harness.startCtx,
  );
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  const settled = settlePayload(socket, before)!;
  // The bounded message is replaced by a `{truncated:true,bytes}` marker; the
  // snippet must come from the original message, so it is never the fallback.
  assert.ok(settled.text.length > 0, 'must not fall back to empty');
  assert.ok(
    Array.from(settled.text).length <= SETTLED_TEXT_MAX_CODE_POINTS,
    'must respect the wire cap',
  );
  assert.equal(settled.truncated, true);
});

test('a user message_end does not clobber the cached assistant text', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    { type: 'message_end', message: { role: 'assistant', content: 'the answer' } },
    harness.startCtx,
  );
  handler({ type: 'message_end', message: { role: 'user', content: 'steer' } }, harness.startCtx);
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  assert.deepEqual(settlePayload(socket, before), {
    kind: 'settled',
    text: 'the answer',
    truncated: false,
  });
});

test('a toolResult message_end does not clobber the cached assistant text', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    { type: 'message_end', message: { role: 'assistant', content: 'the answer' } },
    harness.startCtx,
  );
  handler(
    { type: 'message_end', message: { role: 'toolResult', content: 'output' } },
    harness.startCtx,
  );
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  assert.deepEqual(settlePayload(socket, before), {
    kind: 'settled',
    text: 'the answer',
    truncated: false,
  });
});

test("a second turn's settle carries only the second turn's text", () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    { type: 'message_end', message: { role: 'assistant', content: 'first' } },
    harness.startCtx,
  );
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  harness.pi.handlers.get('agent_start')!({ type: 'agent_start' }, harness.startCtx);
  handler(
    { type: 'message_end', message: { role: 'assistant', content: 'second' } },
    harness.startCtx,
  );
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  assert.deepEqual(settlePayload(socket, before), {
    kind: 'settled',
    text: 'second',
    truncated: false,
  });
});

test('a settle with no assistant message carries empty text', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  assert.deepEqual(settlePayload(socket, before), {
    kind: 'settled',
    text: '',
    truncated: false,
  });
});
