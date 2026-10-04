/**
 * Transcript projection: history windows, cursors, the session tree, and the
 * model and context-usage readings the app renders.
 */

import { createHash } from 'node:crypto';

import { asObject, asString } from '../protocol/protocol.ts';
import type { ModelSummary, TreeNodeSummary } from '../protocol/protocol.ts';
import { trimOversizedImageParts } from './normalize.ts';
import { boundToolPayload, toolCallIdentity, toolCallPayloads, toolResultPayload } from './tool-views.ts';
import type { BridgeCtx } from './pi-types.ts';

/** The pi message inside a transcript entry: a history entry is
 * `{type:'message', message:{…}}`; a bare message is itself. */
function entryMessage(entry: unknown): Record<string, unknown> | null {
  const obj = asObject(entry);
  if (obj === null) return null;
  if (obj.message !== undefined) return asObject(obj.message);
  return obj;
}

/** Indexes every assistant tool-call argument by call id across the entries. */
export function collectToolArgs(entries: readonly unknown[]): Map<string, unknown> {
  const argsById = new Map<string, unknown>();
  for (const entry of entries) {
    const message = entryMessage(entry);
    if (message === null || message.role !== 'assistant' || !Array.isArray(message.content)) {
      continue;
    }
    for (const part of message.content) {
      const call = asObject(part);
      if (call === null || call.type !== 'toolCall') continue;
      const id = asString(call.id);
      if (id !== null) argsById.set(id, call.arguments);
    }
  }
  return argsById;
}

/**
 * The unpaired tool calls' arguments: a call whose id already has a
 * `toolResult` entry cannot still be in flight, so it is never seeded. Only an
 * unpaired call can still resolve a result — issue #20.
 */
export function collectUnpairedToolArgs(entries: readonly unknown[]): Map<string, unknown> {
  const paired = new Set<string>();
  for (const entry of entries) {
    const message = entryMessage(entry);
    if (message === null || message.role !== 'toolResult') continue;
    const id = asString(message.toolCallId);
    if (id !== null) paired.add(id);
  }
  const unpaired = new Map<string, unknown>();
  for (const [id, args] of collectToolArgs(entries)) {
    if (!paired.has(id)) unpaired.set(id, args);
  }
  return unpaired;
}

/**
 * Replays entries with synthesized `tool` frames inserted after each assistant
 * tool call and each tool result, so a snapshot carries the same normalized
 * views as the live relay. Every inserted frame is bounded; non-message entries
 * are copied through untouched.
 */
export function annotateToolViews(entries: readonly unknown[]): unknown[] {
  const argsById = collectToolArgs(entries);
  const annotated: unknown[] = [];
  for (const entry of entries) {
    annotated.push(entry);
    const message = entryMessage(entry);
    if (message === null) continue;
    if (message.role === 'assistant') {
      for (const payload of toolCallPayloads(message, argsById)) {
        annotated.push(boundToolPayload(payload));
      }
    } else if (message.role === 'toolResult') {
      const payload = toolResultPayload(message, argsById);
      if (payload !== null) annotated.push(boundToolPayload(payload));
    }
  }
  return annotated;
}

/** The most `/tree` nodes a `listTree` result may carry. */
export const TREE_MAX_NODES = 200;

export interface HistoryProjection {
  entries: unknown[];
  truncated: boolean;
  /** Absolute index in the passed array of the oldest kept entry. */
  start: number;
}

/** The image-part trim for one history entry, rebuilding whatever shape was
 * unwrapped: a `{type:'message', message}` wrapper keeps its wrapper, a bare
 * `{role, content}` message stays bare. Null when the entry is not a message or
 * the trim could not rescue it. */
function trimHistoryEntry(entry: unknown, maxBytes: number): unknown | null {
  const message = entryMessage(entry);
  if (message === null) return null;
  const trimmed = trimOversizedImageParts(message, maxBytes);
  if (trimmed === null) return null;
  const obj = asObject(entry);
  if (obj === null) return null;
  return obj.message !== undefined ? { ...obj, message: trimmed } : trimmed;
}

/**
 * The most recent entries that fit in `maxBytes`, in chronological order.
 *
 * A *suffix* window, not a prefix. This frame is replayed to a viewer on every
 * subscribe/reconnect, so the newest entries are the ones that must survive:
 * a prefix window drops exactly the recent turns the viewer is looking for,
 * which reads on the phone as "the session ends at some old message" even
 * though live events keep arriving. Walking backwards and reversing keeps the
 * kept run contiguous and chronological. `truncated` means the *older* entries
 * were omitted.
 *
 * `end` bounds the walk at an older cursor's offset, so the same function mints
 * both the newest baseline (`end = entries.length`) and every older page. A
 * 2-argument call is unchanged.
 */
export function projectHistory(
  entries: readonly unknown[],
  maxBytes: number,
  end: number = entries.length,
): HistoryProjection {
  const kept: unknown[] = [];
  let bytes = 2; // the enclosing `[]`
  const sized = (value: unknown): number =>
    Buffer.byteLength(JSON.stringify(value) ?? 'null') + (kept.length > 0 ? 1 : 0);
  for (let index = end - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    const serialized = JSON.stringify(entry) ?? 'null';
    let value = entry;
    let size = sized(entry);
    if (size > maxBytes) {
      // An entry no window could ever hold (a 1.4 MB tool result is real here)
      // would otherwise be a hard wall: it stops the walk and leaves most of
      // the budget unspent. Prefer an image-part trim, which keeps the entry's
      // text; collapse to the notice marker only when that cannot rescue it.
      const trimmed = trimHistoryEntry(entry, maxBytes);
      if (trimmed !== null) {
        value = trimmed;
        size = sized(value);
      }
      // Fall back to the whole-entry marker whenever the entry still cannot
      // fit — the trim failed, the trimmed value still busts the cap, or it no
      // longer fits the *remaining* window. Doing this BEFORE the `break`
      // preserves today's behaviour: a slightly oversized entry collapses to a
      // tiny marker and the walk CONTINUES, keeping older entries rather than
      // dropping them and flipping the window flag.
      if (size > maxBytes || bytes + size > maxBytes) {
        value = { truncated: true, bytes: Buffer.byteLength(serialized) };
        size = sized(value);
      }
    }
    if (bytes + size > maxBytes) break;
    bytes += size;
    kept.push(value);
  }
  kept.reverse();
  return {
    entries: kept,
    truncated: kept.length < end,
    start: end - kept.length,
  };
}

/**
 * A short digest of one entry **bound to its offset**, so two identical entries
 * at different positions cannot alias: a stale offset cannot validate against
 * the wrong entry. One hash per page.
 */
export function entryAnchor(offset: number, value: unknown): string {
  return createHash('sha256')
    .update(`${offset}:${JSON.stringify(value) ?? 'null'}`)
    .digest('hex')
    .slice(0, 16);
}

/** The opaque cursor naming the oldest entry already delivered at `index`. */
export function mintCursor(annotated: readonly unknown[], index: number): string {
  return `${index}:${entryAnchor(index, annotated[index])}`;
}

/** Split a minted cursor on its first `:`, validating the offset only. A null
 * return (unparseable) degrades to a newest-page baseline, never an error. */
export function parseHistoryCursor(raw: string): { offset: number; anchor: string } | null {
  const separator = raw.indexOf(':');
  if (separator < 0) return null;
  const offsetText = raw.slice(0, separator);
  if (!/^\d+$/.test(offsetText)) return null;
  const offset = Number(offsetText);
  if (!Number.isSafeInteger(offset)) return null;
  return { offset, anchor: raw.slice(separator + 1) };
}

/**
 * Flattens pi's session tree into the picker's bounded node list.
 *
 * Only a `message` entry whose role is `user`/`assistant` is emitted; every
 * other entry (the other `SessionEntry` variants, tool results, system/custom
 * messages) is traversed but not emitted, so message nodes below it are still
 * reached.
 *
 * `getTree()` is typed `unknown` here because the bridge's pi slice is
 * structural, so every access is defensive: a malformed node is skipped, never
 * thrown. It is called inside dispatch, where a throw would surface as a
 * generic refusal.
 *
 * Nodes are flattened in DFS order (parents before children, children in array
 * order) and the newest `cap` are kept. An emitted node whose parent was
 * dropped off the front is relinked to the top, so the app's indentation can
 * never point at a missing id.
 */
export function projectTree(
  roots: unknown,
  cap = TREE_MAX_NODES,
): { nodes: TreeNodeSummary[]; truncated: boolean } {
  const emitted: Array<{ node: TreeNodeSummary; parentId: string | null }> = [];

  const visit = (raw: unknown, nearestEmittedId: string | null): void => {
    const treeNode = asObject(raw);
    if (treeNode === null) return;
    const entry = asObject(treeNode.entry);
    if (entry === null) return;
    const id = asString(entry.id);
    const message = asObject(entry.message);
    const role = message === null ? undefined : asString(message.role);
    let nextNearest = nearestEmittedId;
    if (entry.type === 'message' && id !== null && (role === 'user' || role === 'assistant')) {
      const node: TreeNodeSummary = {
        id,
        parentId: nearestEmittedId,
        role,
        text: projectedMessageText(role, message as Record<string, unknown>),
      };
      const label = asString(treeNode.label);
      if (label !== null) node.label = label;
      emitted.push({ node, parentId: nearestEmittedId });
      nextNearest = id;
    }
    const children = treeNode.children;
    if (!Array.isArray(children)) return;
    for (const child of children) visit(child, nextNearest);
  };

  if (Array.isArray(roots)) {
    for (const root of roots) visit(root, null);
  }

  const truncated = emitted.length > cap;
  const kept = truncated ? emitted.slice(emitted.length - cap) : emitted;
  const keptIds = new Set(kept.map((item) => item.node.id));
  const nodes = kept.map((item) =>
    item.parentId !== null && keptIds.has(item.parentId)
      ? item.node
      : { ...item.node, parentId: null },
  );
  return { nodes, truncated };
}

/**
 * The text of one emitted node. A user message's content may be a string or
 * parts; an image part is marked rather than dropped. Assistant text parts are
 * joined; when a turn has no text at all — a tool/thinking-only turn — it is
 * labelled by what it actually contained instead of being left empty: its tool
 * names (deduplicated, first-seen order) if it called any, otherwise
 * `(thinking)`. A turn that has text is never altered by this fallback.
 */
function projectedMessageText(
  role: 'user' | 'assistant',
  message: Record<string, unknown>,
): string {
  const content = message.content;
  if (role === 'user' && typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  let text = '';
  let hasThinking = false;
  const toolNames: string[] = [];
  for (const part of content) {
    const obj = asObject(part);
    if (obj === null) continue;
    if (role === 'user') {
      if (obj.type === 'text' && typeof obj.text === 'string') text += obj.text;
      else text += '[image]';
    } else if (obj.type === 'text' && typeof obj.text === 'string') {
      text += obj.text;
    } else if (obj.type === 'thinking') {
      hasThinking = true;
    } else {
      const call = toolCallIdentity(obj);
      if (call !== null && !toolNames.includes(call.name)) toolNames.push(call.name);
    }
  }
  if (role === 'assistant' && text === '') {
    if (toolNames.length > 0) return `(tool calls: ${toolNames.join(', ')})`;
    if (hasThinking) return '(thinking)';
  }
  return text;
}

/**
 * Projects a pi `Model` onto the three fields the app needs. Deliberately not a
 * passthrough: a `Model` carries `headers` (credentials), `baseUrl`, `compat`
 * and cost data, none of which may leave the bridge. Returns null unless
 * `provider`, `id` and `name` are all strings, so a malformed registry entry is
 * skipped rather than sent half-formed.
 */
export function projectModel(value: unknown): ModelSummary | null {
  const model = asObject(value);
  if (model === null) return null;
  const provider = asString(model.provider);
  const id = asString(model.id);
  const name = asString(model.name);
  if (provider === null || id === null || name === null) return null;
  return { provider, id, name };
}

/**
 * pi's own context-usage reading, if the host exposes one and has a model with a
 * known window. Deliberately not a passthrough of the whole object: only the two
 * numbers the app renders travel, so a field added to pi's `ContextUsage` later
 * cannot change the wire by accident.
 *
 * Structural on purpose — an older pi has no such method, and that must be a
 * missing label rather than a crash.
 */
export function readContextUsage(
  ctx: BridgeCtx,
): { tokens: number | null; contextWindow: number } | null {
  const usage = ctx.getContextUsage?.();
  if (usage === undefined) return null;
  return { tokens: usage.tokens, contextWindow: usage.contextWindow };
}
