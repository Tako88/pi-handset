// live wiring and history replay.
// Split from the bridge test file; test blocks are byte-exact.
//
// Preserved from the original bridge test file:
//
// ---------------------------------------------------------------------------
// Live wiring and history replay
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { test, beforeEach } from 'node:test';
import { HISTORY_MAX_BYTES, type ToolPayload } from '../src/protocol/protocol.ts';
import { resetSessionLinkageForTests } from './pi-handset-bridge.ts';
import { makeCtx, makeHarness, parsed, sendCommand } from '../test/support/bridge-harness.ts';

beforeEach(() => resetSessionLinkageForTests());

test('a message_end emits its tool frames after the message, in order', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0];
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
  assert.equal(frames[1].status, 'running');
  assert.equal(frames[1].name, 'bash');
  assert.deepEqual(frames[1].view, { type: 'generic', target: 'echo hi' });
  assert.equal(frames[3].status, 'done');
  assert.deepEqual(frames[3].view, {
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
  const socket = harness.sockets[0];
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
