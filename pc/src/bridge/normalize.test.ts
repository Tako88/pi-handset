/**
 * Normalization of raw pi assistant events and message-end frames, exercised
 * through `src/bridge/normalize.ts`.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  EVENT_PAYLOAD_KINDS,
  MAX_RELAY_BYTES,
  PROTOCOL_VERSION,
} from '../protocol/protocol.ts';
import type { AssistantMessageEvent, MessageEndEvent } from './pi-types.ts';
import { normalizeAssistantEvent, normalizeMessageEnd } from './normalize.ts';
import { sampleAssistantEvent, imagePart } from '../../test/support/bridge-harness.ts';

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

test('thinking_delta streams its chunk, tagged with the thinking phase', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('thinking_delta'), 1);
  assert.deepEqual(result, {
    kind: 'emit',
    payload: { kind: 'stream', seq: 1, text: 'hmm', phase: 'thinking' },
  });
});

test('thinking_end emits nothing: the committed message is authoritative', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('thinking_end'), 1);
  assert.equal(result.kind, 'ignore');
  if (result.kind !== 'ignore') return;
  assert.equal(result.reason, 'thinking-end-committed-message-authoritative');
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

// ---------------------------------------------------------------------------
// In-place image-part trim (#32)
// ---------------------------------------------------------------------------
// A message oversized only because of an image part is trimmed in place: the
// image becomes `{type:'image',truncated:true,bytes}` and the message keeps its
// role and text. A message that cannot be rescued that way (text alone busts
// the cap, no trimmable part, or too many parts) keeps the whole-message marker
// as the fallback.

test('an oversized image part is replaced in place and the text survives', () => {
  const image = imagePart(MAX_RELAY_BYTES + 1);
  const huge = { role: 'user', content: [{ type: 'text', text: 'look at this' }, image] };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal(result.payload.kind, 'message');
  const payload = result.payload as unknown as {
    message: { role?: string; content?: unknown[] };
    truncated?: boolean;
  };
  assert.equal(payload.truncated, true);
  assert.equal(payload.message.role, 'user');
  assert.deepEqual(payload.message.content?.[0], { type: 'text', text: 'look at this' });
  assert.deepEqual(payload.message.content?.[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(image)),
  });
  // Bounded to the MESSAGE cap only (R1 policy (a)): the hub budgets the whole
  // frame, and a message at the cap makes an over-budget frame. Asserting the
  // encoded frame fits would be false near the cap, so it is deliberately not
  // asserted here.
  assert.ok(
    Buffer.byteLength(JSON.stringify(payload.message)) <= MAX_RELAY_BYTES,
    'the trimmed message must serialize within the shared cap',
  );
});

test('an oversized assistant message_end keeps its role and text', () => {
  const image = imagePart(MAX_RELAY_BYTES + 1, 'image/jpeg');
  const huge = { role: 'assistant', content: [{ type: 'text', text: 'here' }, image] };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as unknown as {
    message: { role?: string; content?: unknown[] };
    truncated?: boolean;
  };
  assert.equal(payload.truncated, true);
  assert.equal(payload.message.role, 'assistant');
  assert.deepEqual(payload.message.content?.[0], { type: 'text', text: 'here' });
  assert.deepEqual(payload.message.content?.[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(image)),
  });
});

test('only the image parts it takes to fit are trimmed', () => {
  const big = imagePart(200_000);
  const small = imagePart(100_000);
  const huge = { role: 'user', content: [{ type: 'text', text: 'hi' }, big, small] };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as unknown as { message: { content?: unknown[] } };
  const content = payload.message.content ?? [];
  assert.equal(content.length, 3);
  // Largest first: the 200 KB part goes, the 100 KB part stays intact, and
  // exactly one part carries the marker.
  assert.deepEqual(content[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(big)),
  });
  assert.deepEqual(content[2], small);
  assert.equal(content.filter((part) => (part as { truncated?: boolean }).truncated === true).length, 1);
});

test('a toolResult message with an oversized image keeps its text', () => {
  const image = imagePart(MAX_RELAY_BYTES + 1);
  const huge = {
    role: 'toolResult',
    toolCallId: 'call-1',
    toolName: 'read',
    content: [{ type: 'text', text: 'file body' }, image],
    isError: false,
  };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as unknown as { message: { role?: string; content?: unknown[] } };
  assert.equal(payload.message.role, 'toolResult');
  assert.deepEqual(payload.message.content?.[0], { type: 'text', text: 'file body' });
  assert.deepEqual(payload.message.content?.[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(image)),
  });
});

// PIN: green today. NC-5b removes the whole-message fallback.
test('an oversized text-only message still falls back to the whole-message marker', () => {
  const huge = { role: 'assistant', content: [{ type: 'text', text: 'x'.repeat(MAX_RELAY_BYTES + 1) }] };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as { message?: unknown; truncated?: boolean };
  assert.equal(payload.truncated, true);
  assert.deepEqual(payload.message, { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) });
});

// PIN: green today. NC-5b removes the whole-message fallback.
test('a message whose own text busts the cap falls back to the marker', () => {
  const huge = {
    role: 'user',
    content: [{ type: 'text', text: 'x'.repeat(MAX_RELAY_BYTES + 1) }, imagePart(4)],
  };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as { message?: unknown };
  assert.deepEqual(payload.message, { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) });
});

// PIN: green today. NC-5c removes the `bytes <= maxBytes` early-return in
// `boundMessage`, forcing this already-fitting message down the trim path:
// nothing is trimmed, `trimmed === false`, and the whole-message marker is
// returned. Observed red: `payload.truncated` expected false, actual true
// (`true !== false` at the `assert.equal(payload.truncated, false)` line).
test('a small message with a small image is forwarded byte-for-byte', () => {
  const small = { role: 'user', content: [{ type: 'text', text: 'hi' }, imagePart(4)] };
  const result = normalizeMessageEnd({ type: 'message_end', message: small });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as { message?: unknown; truncated?: boolean };
  assert.equal(payload.truncated, false);
  assert.deepEqual(payload.message, small);
});

// PIN: green today. NC-5b removes the whole-message fallback.
test('a message with a non-string image data part and oversized text falls back to the whole marker', () => {
  const huge = {
    role: 'user',
    content: [{ type: 'text', text: 'x'.repeat(MAX_RELAY_BYTES + 1) }, { type: 'image', data: 123 }],
  };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as { message?: unknown };
  assert.deepEqual(payload.message, { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) });
});

// PIN: green today. NC-10 raises TRIM_MAX_ITERATIONS past the bound.
test('a message with more image parts than the trim bound falls back to the whole message marker', () => {
  // Each part must be large enough that more than TRIM_MAX_ITERATIONS (64) of
  // them have to go before the message fits: after 64 trims, the 6 remaining
  // 50 KB parts still exceed the cap, so the loop hits its bound and the whole
  // marker is the fallback. (With the parts too small the loop would succeed
  // well inside the bound and this pin would be vacuous.)
  const parts = Array.from({ length: 70 }, () => imagePart(50_000));
  const huge = { role: 'user', content: parts };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as { message?: unknown };
  assert.deepEqual(payload.message, { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) });
});
