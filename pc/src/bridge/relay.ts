/** Mapping pi's live events onto the wire and the turn-scoped state they carry. */

import { asString } from '../protocol/protocol.ts';
import type { EventPayload } from '../protocol/protocol.ts';
import { normalizeAssistantEvent, normalizeMessageEnd } from './normalize.ts';
import { boundToolPayload, toolCallPayloads, toolResultPayload } from './tool-views.ts';
import { collectToolArgs, collectUnpairedToolArgs } from './history.ts';
import { messageText, SETTLED_TEXT_MAX_CODE_POINTS, settleText } from './labels.ts';
import type { AssistantMessageEvent, MessageEndEvent } from './pi-types.ts';

/** The pi-event → wire mappings and the per-turn state they read and write. */
export interface Relay {
  resetSession(): void;
  seedToolArgs(entries: readonly unknown[]): void;
  resetTurn(): void;
  clearHeldArgs(): void;
  sendSettled(): void;
  onMessageUpdate(event: unknown): void;
  onMessageEnd(event: unknown): void;
  onSessionTree(event: unknown): void;
  onCompactFailed(event: unknown): void;
}

export function createRelay(hooks: {
  sendEvent(payload: EventPayload): void;
  relabelFromMessage(message: unknown): void;
}): Relay {
  let seq = 0;
  /** The current turn's final assistant snippet, reset at each turn start. */
  let lastSettled: { text: string; truncated: boolean } = { text: '', truncated: false };
  /** Tool-call arguments by call id, held only while a call can still resolve
   * its `toolResult` (which carries none). Filled by the live assistant
   * `message_end` and, at session start, only for entries calls with no recorded
   * result; released when the result is emitted and cleared when the turn
   * settles. A completed call is never held — see issue #20. */
  const toolArgs = new Map<string, unknown>();

  function resetSession(): void {
    seq = 0;
    lastSettled = { text: '', truncated: false };
    toolArgs.clear();
  }

  /**
   * Seeds the held arguments from the session's entries. Only calls with no
   * recorded result can still be in flight: a call whose `toolResult` is already
   * in the entries can never produce another, so seeding it would retain its
   * arguments for the session. `reload` is the reason that can strand an
   * unpaired call across an instance boundary.
   */
  function seedToolArgs(entries: readonly unknown[]): void {
    for (const [id, args] of collectUnpairedToolArgs(entries)) toolArgs.set(id, args);
  }

  function resetTurn(): void {
    // A new turn starts with no reply, so a settle before any assistant
    // message cannot inherit the previous turn's text.
    lastSettled = { text: '', truncated: false };
  }

  function clearHeldArgs(): void {
    // A settled turn has no in-flight calls, so anything still held is an
    // aborted call no result will ever consume.
    toolArgs.clear();
  }

  /** Emits the cached turn snippet, after the terminal state and usage. */
  function sendSettled(): void {
    hooks.sendEvent({
      kind: 'settled',
      text: lastSettled.text,
      truncated: lastSettled.truncated,
    });
  }

  function onMessageUpdate(event: unknown): void {
    const assistantEvent = (event as { assistantMessageEvent?: AssistantMessageEvent })
      .assistantMessageEvent;
    if (assistantEvent === undefined) return;
    const candidate = seq + 1;
    const normalized = normalizeAssistantEvent(assistantEvent, candidate);
    if (normalized.kind === 'ignore') return;
    if (normalized.payload.kind === 'stream') seq = candidate;
    hooks.sendEvent(normalized.payload);
  }

  function onMessageEnd(event: unknown): void {
    const normalized = normalizeMessageEnd(event as MessageEndEvent);
    if (normalized.kind === 'ignore') return;
    hooks.sendEvent(normalized.payload);
    // A tool call/result follows its own message frame, so the app can pair the
    // normalized view with the row the message produced.
    const original = (event as { message?: unknown }).message;
    const originalRole =
      typeof original === 'object' && original !== null
        ? (original as { role?: unknown }).role
        : undefined;
    if (originalRole === 'assistant') {
      for (const payload of toolCallPayloads(original, toolArgs)) {
        hooks.sendEvent(boundToolPayload(payload));
      }
      for (const [id, args] of collectToolArgs([original])) toolArgs.set(id, args);
    } else if (originalRole === 'toolResult') {
      const payload = toolResultPayload(original, toolArgs);
      // Delete before the send: the result is the only reader that needs the
      // arguments, and a throw out of `sendEvent` must not skip the release.
      const toolCallId = asString((original as { toolCallId?: unknown }).toolCallId);
      if (toolCallId !== null) toolArgs.delete(toolCallId);
      if (payload !== null) hooks.sendEvent(boundToolPayload(payload));
    }
    // The snippet comes from the ORIGINAL message, never the bounded payload:
    // an oversized reply is replaced by a `{truncated:true,bytes}` marker, and
    // caching that marker would make every huge reply notify `'No reply'`.
    if (originalRole === 'assistant') {
      lastSettled = settleText(
        messageText((original as { content?: unknown }).content),
        SETTLED_TEXT_MAX_CODE_POINTS,
      );
    }
    // The live path uses the event's own message, never the entries scan: pi
    // persists the message only after this event, so `getEntries()` is stale.
    hooks.relabelFromMessage((event as { message?: unknown }).message);
  }

  /**
   * Maps pi's `session_tree` event to the `leaf` payload. A `null` `newLeafId`
   * (navigated to the root) is preserved, not omitted: absent means "an older
   * bridge", which the app cannot tell from "at the root".
   */
  function onSessionTree(event: unknown): void {
    const raw = (event as { newLeafId?: unknown } | null)?.newLeafId;
    const leafId = typeof raw === 'string' && raw.length > 0 ? raw : null;
    hooks.sendEvent({ kind: 'leaf', leafId });
  }

  /**
   * Surfaces a failed compaction as an error notice. Gated on a non-empty
   * `errorMessage`, which also excludes a deliberately aborted compaction (pi
   * leaves `errorMessage` undefined for those). No `reason` filter: manual,
   * overflow and threshold failures are all reported.
   */
  function onCompactFailed(event: unknown): void {
    const errorMessage =
      typeof event === 'object' && event !== null
        ? (event as { errorMessage?: unknown }).errorMessage
        : undefined;
    if (typeof errorMessage !== 'string' || errorMessage.length === 0) return;
    hooks.sendEvent({ kind: 'status', event: 'error', message: errorMessage });
  }

  return {
    resetSession,
    seedToolArgs,
    resetTurn,
    clearHeldArgs,
    sendSettled,
    onMessageUpdate,
    onMessageEnd,
    onSessionTree,
    onCompactFailed,
  };
}
