/**
 * Normalizing pi's events and payloads onto the wire.
 *
 * `normalizeAssistantEvent` and `normalizeMessageEnd` are total and explicit:
 * every variant either emits or states why it is ignored. `boundMessage` keeps
 * an oversized message under the relay cap by trimming image parts, then by
 * collapsing it to a marker.
 */

import { MAX_RELAY_BYTES, asObject, asString } from '../protocol/protocol.ts';
import type { EventPayload } from '../protocol/protocol.ts';
import type { AssistantMessageEvent, ImagePart, MessageEndEvent } from './pi-types.ts';

/** Either a normalized payload to send, or a stated reason for dropping it. */
export type NormalizedEvent =
  | { kind: 'emit'; payload: EventPayload }
  | { kind: 'ignore'; reason: string };

function errorText(error: unknown): string {
  if (typeof error === 'object' && error !== null) {
    const message = (error as { errorMessage?: unknown }).errorMessage;
    if (typeof message === 'string' && message.length > 0) return message;
  }
  return 'error';
}

/**
 * The `images` argument of a send command, as `{type:'image',data,mimeType}`
 * parts. Absent, `null` or an empty array means "no images"; a non-array or any
 * element whose `data`/`mimeType` is not a non-empty string refuses the whole
 * command. `type` is not read: the element is rebuilt flat, so pi always sees
 * the exact `ImageContent` shape.
 */
export function parseImages(
  value: unknown,
): { ok: true; images?: ImagePart[] } | { ok: false } {
  if (value === undefined || value === null) return { ok: true };
  if (!Array.isArray(value)) return { ok: false };
  if (value.length === 0) return { ok: true };
  const images: ImagePart[] = [];
  for (const element of value) {
    const part = asObject(element);
    if (part === null) return { ok: false };
    const data = asString(part.data);
    const mimeType = asString(part.mimeType);
    if (data === null || mimeType === null) return { ok: false };
    images.push({ type: 'image', data, mimeType });
  }
  return { ok: true, images };
}

/**
 * The most image parts the trim loop may replace before giving up.
 *
 * ponytail: the loop is capped at this many iterations; each iteration
 * re-serializes the whole message, so an unbounded loop on a pathological
 * message with thousands of image parts would multiply hundreds-of-KiB
 * stringifies on the event loop. Past the bound the whole-message marker is the
 * fallback. Raise the bound if a real message ever needs more.
 */
export const TRIM_MAX_ITERATIONS = 64;

/**
 * Replaces the largest image part, one at a time, with `{type:'image',
 * truncated:true,bytes}` until the message fits, and returns the trimmed
 * message; null when it cannot be rescued (no image part left, the remaining
 * text alone still busts the cap, or the part count exceeds the iteration
 * bound). Text parts are never touched, and a message that already fits never
 * needs this. Terminates because a marker part has no string `data` and so is
 * never chosen twice.
 */
export function trimOversizedImageParts(message: unknown, maxBytes: number): unknown | null {
  const obj = asObject(message);
  if (obj === null || !Array.isArray(obj.content)) return null;
  const content = [...obj.content];
  const fits = (): boolean =>
    Buffer.byteLength(JSON.stringify({ ...obj, content })) <= maxBytes;
  let trimmed = false;
  for (let guard = 0; guard < TRIM_MAX_ITERATIONS && !fits(); guard += 1) {
    let index = -1;
    let size = -1;
    for (let i = 0; i < content.length; i += 1) {
      const part = asObject(content[i]);
      if (part === null || part.type !== 'image' || typeof part.data !== 'string') continue;
      const bytes = Buffer.byteLength(JSON.stringify(part));
      if (bytes > size) {
        size = bytes;
        index = i;
      }
    }
    if (index === -1) break;
    content[index] = { type: 'image', truncated: true, bytes: size };
    trimmed = true;
  }
  return trimmed && fits() ? { ...obj, content } : null;
}

/**
 * Bounds an agent-supplied `message` to the shared relay cap. A message that
 * fits is returned untouched; an oversized one whose bulk is an image part is
 * trimmed in place (the image becomes a marker, the role and text survive);
 * anything that cannot be rescued that way is replaced by a small marker, so it
 * cannot exceed the hub's frame cap and cost the transcript a message.
 *
 * The target is the *message*, never the hub's frame: `sendToViewer` budgets
 * the whole `{protocolVersion,type,payload}` envelope against the same cap, so a
 * message at the cap makes an over-budget frame that is dropped (R1 policy (a);
 * see docs/known-limits.md).
 */
function boundMessage(
  message: unknown,
  maxBytes: number,
): { message: unknown; truncated: boolean } {
  const serialized = JSON.stringify(message) ?? 'null';
  const bytes = Buffer.byteLength(serialized);
  if (bytes <= maxBytes) return { message, truncated: false };
  const trimmed = trimOversizedImageParts(message, maxBytes);
  if (trimmed !== null) return { message: trimmed, truncated: true };
  return { message: { truncated: true, bytes }, truncated: true };
}

/**
 * Maps one pi assistant-stream event to at most one normalized protocol
 * payload. Total and explicit: every variant either emits or states why it is
 * ignored, and an unrecognized variant is *also* an explicit ignore.
 *
 * Text and reasoning deltas stream content; the final `done` message and `error`
 * status are forwarded so the transcript can settle, and `thinking_start` emits a
 * content-free phase frame so the status indicator can say "Thinking…" before the
 * first reasoning chunk lands. Tool-call deltas are deliberately not streamed:
 * the call arrives whole in the committed message.
 */
export function normalizeAssistantEvent(
  event: AssistantMessageEvent,
  seq: number,
): NormalizedEvent {
  switch (event.type) {
    case 'text_delta':
      return { kind: 'emit', payload: { kind: 'stream', seq, text: event.delta } };
    case 'done': {
      // Real pi does NOT forward a `done` assistantMessageEvent on
      // `message_update`; assistant completion arrives as the `message_end`
      // extension event, handled by `normalizeMessageEnd` (the live producer).
      // This branch is retained because `done` is part of the transcribed pi-ai
      // union and the exhaustive switch below depends on it — not because it
      // fires. Do not "fix" it back to being the producer.
      const bounded = boundMessage(event.message, MAX_RELAY_BYTES);
      return {
        kind: 'emit',
        payload: { kind: 'message', message: bounded.message, truncated: bounded.truncated },
      };
    }
    case 'error':
      return {
        kind: 'emit',
        payload: { kind: 'status', event: 'error', message: errorText(event.error) },
      };
    case 'start':
    case 'text_start':
    case 'text_end':
      return { kind: 'ignore', reason: `block-${event.type}` };
    case 'thinking_start':
      // A content-free liveness phase: the block is empty at `*_start` (pi-ai
      // types.d.ts). The reasoning text follows as `thinking_delta` frames, each
      // carrying one chunk in `text` with the same phase.
      return { kind: 'emit', payload: { kind: 'stream', seq, phase: 'thinking' } };
    case 'thinking_delta':
      // Reasoning streams like answer text, tagged so the app routes it to its
      // own buffer instead of the reply. `thinking_start` still arrives first
      // as a content-free liveness frame, so a slow first token is never
      // mislabelled.
      return {
        kind: 'emit',
        payload: { kind: 'stream', seq, text: event.delta, phase: 'thinking' },
      };
    case 'thinking_end':
      // Deliberately ignored, and NOT a silent drop: `thinking_end` carries the
      // whole text of one thinking block, so emitting it would make a second
      // producer of text the deltas already streamed. The committed assistant
      // message arrives immediately after and is authoritative.
      return { kind: 'ignore', reason: 'thinking-end-committed-message-authoritative' };
    case 'toolcall_start':
    case 'toolcall_delta':
    case 'toolcall_end':
      return { kind: 'ignore', reason: 'tool-calls-not-streamed' };
    default: {
      // Compile-time exhaustiveness: a new variant lands here as a type error.
      const unreachable: never = event;
      void unreachable;
      const type = (event as { type?: string }).type ?? 'unknown';
      return { kind: 'ignore', reason: `unknown-assistant-event:${type}` };
    }
  }
}

/** The roles whose `message_end` is relayed. `user` carries the user's own
 * prompt (M1: own messages in the transcript); `assistant` carries the
 * committed reply. `toolResult` (M2) carries a tool's output and is relayed
 * only now that `deriveBlocks` pairs it into its call and `ToolBlock` renders
 * it — relaying it a milestone earlier would have shipped unlabelled tool
 * noise. `system`/`custom`/unknown stay ignored. */
const RELAYED_MESSAGE_ROLES = new Set(['user', 'assistant', 'toolResult']);

/**
 * Maps pi's `message_end` extension event to at most one normalized payload.
 *
 * This is the live producer of the `message` payload: real pi signals assistant
 * completion with `message_end`, not with a `done` assistantMessageEvent (see
 * the comment on the `done` branch above). `message_end` fires for *every*
 * role — the system prompt, the user's own prompt, tool results — so only a
 * relayed role is sent; every other role is an explicit ignore, never a silent
 * drop.
 */
export function normalizeMessageEnd(event: MessageEndEvent): NormalizedEvent {
  const message = event.message;
  const role =
    typeof message === 'object' && message !== null
      ? (message as { role?: unknown }).role
      : undefined;
  if (typeof role !== 'string' || !RELAYED_MESSAGE_ROLES.has(role)) {
    const label = typeof role === 'string' ? role : 'unknown';
    return { kind: 'ignore', reason: `message-end-unrelayed-role:${label}` };
  }
  const bounded = boundMessage(message, MAX_RELAY_BYTES);
  return {
    kind: 'emit',
    payload: { kind: 'message', message: bounded.message, truncated: bounded.truncated },
  };
}
