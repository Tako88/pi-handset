/**
 * pi-droid bridge — a pi extension that attaches the running session to the hub.
 *
 * The bridge is a *client*: it discovers the hub's ephemeral loopback port in
 * the discovery file, authenticates with the persisted token, registers its
 * session, and relays normalized events. It never exposes pi's own event shapes
 * to the wire and it never dials in the factory — the socket is opened in
 * `session_start` and closed in an idempotent `session_shutdown`.
 *
 * Transport is Node's native `WebSocket` global (client only). `ws` is a server
 * dependency of the hub and is deliberately not imported here. The socket
 * factory, the clock, the RNG, the endpoint resolver and the debug sink are all
 * injectable so the tests never dial and never sleep.
 *
 * # Why the types are structural
 *
 * A type-only import of `@earendil-works/pi-coding-agent` would make `pc/`
 * depend on the host package just to typecheck, and `pc/` is a standalone
 * package. Instead the bridge declares the small slice of `ExtensionAPI`,
 * `ExtensionContext` and `AssistantMessageEvent` it actually touches. The
 * `AssistantMessageEvent` union below is transcribed from
 * `pi-ai/dist/types.d.ts`. The `never` assignment in `normalizeAssistantEvent`'s
 * exhaustive switch only guards that *local transcription*: a variant added or
 * removed there is a compile error, but a 13th variant in real pi compiles green
 * because the live event is cast into this local union. The production
 * protection is the runtime `default`, which turns any unknown variant into an
 * explicit ignore rather than a silent `undefined`.
 */

import { createHash } from 'node:crypto';
import { loadOrCreateToken, resolveConfigDir } from '../src/hub/auth.ts';
import { readDiscovery, resolveRuntimeDir } from '../src/hub/discovery.ts';
import { HISTORY_MAX_BYTES, PROTOCOL_VERSION, asObject, asString, encode } from '../src/protocol/protocol.ts';
import type {
  AgentState,
  AgentToHubMessage,
  CommandMessage,
  CommandResultMessage,
  ContextUsagePayload,
  EventMessage,
  EventPayload,
  HistoryMessage,
  ModelSummary,
  RegisterMessage,
  SlashCommand,
  TreeNodeSummary,
} from '../src/protocol/protocol.ts';
import type { BridgeCommandCtx, BridgeCtx, UserMessageContent, BridgePi, AssistantMessageEvent, MessageEndEvent, BridgeCloseEvent, BridgeSocket, SocketFactory, BridgeDeps } from '../src/bridge/pi-types.ts';
import { parseImages, trimOversizedImageParts, normalizeAssistantEvent, normalizeMessageEnd } from '../src/bridge/normalize.ts';
import { toolCallIdentity, toolCallPayloads, toolResultPayload, boundToolPayload } from '../src/bridge/tool-views.ts';

export type {
  BridgeHandler,
  BridgeSessionManager,
  BridgeCommandCtx,
  BridgeCommandRegistration,
  BridgeModel,
  BridgeModelRegistry,
  BridgeCtx,
  TextPart,
  ImagePart,
  UserMessageContent,
  BridgePi,
  AssistantMessageEvent,
  MessageEndEvent,
  BridgeCloseEvent,
  BridgeSocket,
  SocketFactory,
  BridgeDeps,
} from '../src/bridge/pi-types.ts';
export type {
  NormalizedEvent,
} from '../src/bridge/normalize.ts';
export { TRIM_MAX_ITERATIONS, normalizeAssistantEvent, normalizeMessageEnd } from '../src/bridge/normalize.ts';
export type {
  ToolViewInput,
} from '../src/bridge/tool-views.ts';
export { TOOL_VIEW_MAX_LINES, buildToolView, toolCallPayloads, toolResultPayload, boundToolPayload } from '../src/bridge/tool-views.ts';

/** The pi message inside a transcript entry: a history entry is
 * `{type:'message', message:{…}}`; a bare message is itself. */
function entryMessage(entry: unknown): Record<string, unknown> | null {
  const obj = asObject(entry);
  if (obj === null) return null;
  if (obj.message !== undefined) return asObject(obj.message);
  return obj;
}

/** Indexes every assistant tool-call argument by call id across the entries. */
function collectToolArgs(entries: readonly unknown[]): Map<string, unknown> {
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
function collectUnpairedToolArgs(entries: readonly unknown[]): Map<string, unknown> {
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

/** The modes in which the bridge is active; `json`/`print` stay inert. */
const ACTIVE_MODES = new Set(['tui', 'rpc']);

export function isActiveMode(mode: string): boolean {
  return ACTIVE_MODES.has(mode);
}

/** The bridge's command allowlist. Anything else — including a case- or
 * whitespace-variant of an entry — is refused, because the match is exact.
 * Exported so a test can pin it equal to the hub's copy: the two must not
 * drift, or one side allows what the other refuses. */
export const COMMAND_ALLOWLIST = new Set([
  'prompt',
  'steer',
  'followup',
  'abort',
  'setModel',
  'setThinkingLevel',
  'compact',
  'fetchHistory',
  'setSessionName',
  'listCommands',
  'listModels',
  'listTree',
  'sessionNew',
  'sessionTree',
  'sessionFork',
]);

/**
 * The bridge's own registered command. Its sole purpose is to hand the handler
 * a real `ExtensionCommandContext`, the only surface exposing
 * `newSession`/`fork`/`navigateTree`.
 */
export const SESSION_COMMAND_NAME = 'pi-droid-session';

/**
 * The hub session id the most recently installed bridge registered.
 *
 * Deliberately module scope, not instance scope: pi re-runs the extension
 * factory for every session replacement (the new runtime reloads its resource
 * loader), so the successor's bridge is a *different* instance and instance
 * state cannot name the session it replaced. The module is imported once per
 * pi process, so this value survives the reload and lets the successor carry
 * `replaces`. A `startup` event is a fresh process and overwrites it like any
 * other; a `new`/`fork`/`resume` that differs from it is a real replacement.
 */
let lastRegisteredSessionId: string | null = null;

/**
 * Test-only: clears the module-level predecessor so a unit test cannot inherit
 * a linkage recorded by an earlier test. Production never calls this — a fresh
 * process starts with `null` and every real session transition overwrites it
 * via `onSessionStart`.
 */
export function resetSessionLinkageForTests(): void {
  lastRegisteredSessionId = null;
}

/** The most `/tree` nodes a `listTree` result may carry. */
export const TREE_MAX_NODES = 200;

/**
 * The refusal for a command name the bridge will not dispatch — either because
 * the allowlist has no such name, or because the allowlist has it and the
 * dispatcher has no case for it.
 *
 * Exported and shared so the guard test pins the *path*, not a copy of the
 * string: with two literals, editing one would let a missing case answer with a
 * different message and the guard would pass over a real hole.
 */
export const COMMAND_NOT_ALLOWED = 'command not allowed';

const BACKOFF_BASE_MS = 500;
const BACKOFF_CAP_MS = 30_000;
/**
 * The fixed wait after a `4008` (rate-limited) close: the hub deliberately
 * delays that close, so retrying sooner would only add load. Longer than the
 * first backoff step by construction.
 */
export const RATE_LIMITED_RECONNECT_MS = 30_000;

export interface BackoffOptions {
  rng?: () => number;
}

/** Exponential backoff with full jitter, capped. `attempt` is 0-based. */
export function computeBackoff(attempt: number, options: BackoffOptions = {}): number {
  const rng = options.rng ?? Math.random;
  const ceiling = Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * 2 ** Math.max(0, attempt));
  return Math.floor(rng() * ceiling);
}

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
function projectModel(value: unknown): ModelSummary | null {
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
function readContextUsage(
  ctx: BridgeCtx,
): { tokens: number | null; contextWindow: number } | null {
  const usage = ctx.getContextUsage?.();
  if (usage === undefined) return null;
  return { tokens: usage.tokens, contextWindow: usage.contextWindow };
}

/** The label's cap in Unicode code points, not UTF-16 units, so truncation
 * never leaves a lone surrogate. */
export const LABEL_MAX_CODE_POINTS = 80;

/**
 * Extracts the text of a pi message content value: a string verbatim, or the
 * joined `text` of its `{type:'text'}` parts. An image (or any other) part
 * contributes nothing; an unrecognized shape is empty text.
 */
function messageText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .map((part) => {
      if (typeof part !== 'object' || part === null) return '';
      const candidate = part as { type?: unknown; text?: unknown };
      return candidate.type === 'text' && typeof candidate.text === 'string'
        ? candidate.text
        : '';
    })
    .join(' ');
}

/**
 * The snippet cap in Unicode code points, not UTF-16 units, so a slice never
 * leaves a lone surrogate. Deliberately the wire cap, larger than the app's
 * visible cap (140); keep that ordering if either changes.
 */
export const SETTLED_TEXT_MAX_CODE_POINTS = 200;

/**
 * Bounds a turn's final assistant text to `maxCodePoints` code points for a
 * notification body. Text that fits is returned untouched; a longer string is
 * sliced and flagged `truncated`.
 */
export function settleText(
  text: string,
  maxCodePoints: number,
): { text: string; truncated: boolean } {
  const points = Array.from(text);
  if (points.length <= maxCodePoints) return { text, truncated: false };
  return { text: points.slice(0, maxCodePoints).join(''), truncated: true };
}

/**
 * Trims a raw label to a single sanitized line of at most
 * `LABEL_MAX_CODE_POINTS` code points, or `null` when there is nothing usable.
 * Control characters (including newlines) collapse to spaces, mirroring pi's
 * own session-selector sanitizer; the code-point truncation never splits a
 * surrogate pair.
 */
export function sanitizeLabel(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  if (cleaned.length === 0) return null;
  return Array.from(cleaned).slice(0, LABEL_MAX_CODE_POINTS).join('');
}

/** The label a single transcript entry contributes: a user message's text, or
 * `null` for any other role (and for an image-only user message). */
export function labelFromMessage(message: unknown): string | null {
  if (typeof message !== 'object' || message === null) return null;
  const candidate = message as { role?: unknown; content?: unknown };
  if (candidate.role !== 'user') return null;
  return sanitizeLabel(messageText(candidate.content));
}

/**
 * The last user prompt among transcript entries, or `null`.
 *
 * REGISTER/RECONNECT-TIME ONLY. Real pi persists a message with
 * `sessionManager.appendMessage` *after* it awaits the `message_end` extension
 * event (`agent-session.js`), so a scan of entries during a live turn is stale
 * by one prompt. The live path reads the event's own message
 * (`labelFromMessage`), never this.
 */
export function labelFromEntries(entries: readonly unknown[]): string | null {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (typeof entry !== 'object' || entry === null) continue;
    const label = labelFromMessage((entry as { message?: unknown }).message);
    if (label !== null) return label;
  }
  return null;
}

export interface BridgeEndpoint {
  url: string;
  token: string;
}

export interface EndpointDirs {
  runtimeDir?: string;
  configDir?: string;
}

/** Resolves the hub's loopback URL from discovery and the token from config. */
export function readEndpoint(dirs: EndpointDirs = {}): BridgeEndpoint | null {
  const record = readDiscovery(dirs.runtimeDir ?? resolveRuntimeDir());
  if (record === null) return null;
  let token: string;
  try {
    token = loadOrCreateToken(dirs.configDir ?? resolveConfigDir()).token;
  } catch {
    return null;
  }
  return { url: `ws://127.0.0.1:${record.agentPort}`, token };
}

interface ResolvedDeps {
  env: NodeJS.ProcessEnv;
  socketFactory: SocketFactory;
  resolveEndpoint: () => BridgeEndpoint | null;
  write: (stream: 'stderr', text: string) => void;
  rng: () => number;
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (handle: unknown) => void;
}

const SOCKET_OPEN = 1;

function resolveDeps(deps: BridgeDeps): ResolvedDeps {
  return {
    env: deps.env ?? process.env,
    // Native WebSocket only — no `ws` in the extension.
    socketFactory: deps.socketFactory ?? ((url) => new WebSocket(url) as unknown as BridgeSocket),
    resolveEndpoint: deps.resolveEndpoint ?? (() => readEndpoint()),
    write: deps.write ?? ((_stream, text) => process.stderr.write(text)),
    rng: deps.rng ?? Math.random,
    setTimeout: deps.setTimeout ?? ((fn, ms) => setTimeout(fn, ms)),
    clearTimeout: deps.clearTimeout ?? ((handle) => clearTimeout(handle as NodeJS.Timeout)),
  };
}

function encodeAgentMessage(message: AgentToHubMessage): string {
  // `encode` is the protocol module's single-object encoder for the message
  // types it fully owns (hello/event); the rest are typed by protocol.ts too.
  if (message.type === 'hello' || message.type === 'event') return encode(message);
  return JSON.stringify(message);
}

function parseCommand(message: Record<string, unknown>): CommandMessage | null {
  const id = asString(message.id);
  const sessionId = asString(message.sessionId);
  const name = asString(message.name);
  if (id === null || sessionId === null || name === null) return null;
  const command: CommandMessage = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId,
    name,
  };
  if ('args' in message) command.args = message.args;
  return command;
}

interface CommandOutcome {
  ok: boolean;
  error?: string;
  commands?: SlashCommand[];
  models?: ModelSummary[];
  queued?: boolean;
  tree?: TreeNodeSummary[];
  treeTruncated?: boolean;
  /** The current leaf, on a `listTree` result; `null` is the root. */
  leafId?: string | null;
}

class Bridge {
  private readonly pi: BridgePi;
  private readonly deps: ResolvedDeps;
  private readonly debug: (stream: 'stderr', text: string) => void;
  private socket: BridgeSocket | null = null;
  private ctx: BridgeCtx | null = null;
  private seq = 0;
  private lastLabel: string | null = null;
  private state: AgentState = 'idle';
  /** Tool-call arguments by call id, held only while a call can still resolve
   * its `toolResult` (which carries none). Filled by the live assistant
   * `message_end` and, at session start, only for entries calls with no recorded
   * result; released when the result is emitted and cleared when the turn
   * settles. A completed call is never held — see issue #20. */
  private readonly toolArgs = new Map<string, unknown>();
  /** The current turn's final assistant snippet, reset at each turn start. */
  private lastSettled: { text: string; truncated: boolean } = { text: '', truncated: false };
  private attempt = 0;
  private reconnectTimer: unknown = null;
  private closed = false;
  /** The id the next register must name as replaced, consumed only on a send. */
  private replacesSessionId: string | null = null;
  /** Guards the one-time internal command registration. */
  private sessionCommandsRegistered = false;

  constructor(pi: BridgePi, deps: ResolvedDeps) {
    this.pi = pi;
    this.deps = deps;
    this.debug = (stream, text) => {
      if (deps.env.PI_DROID_DEBUG === '1') deps.write(stream, text);
    };
  }

  install(): void {
    this.registerSessionCommand();
    // The socket is opened here, in the handler, never in the factory. Every
    // pi callback is guarded so an exception cannot escape into pi (which would
    // print to stderr and take the session down).
    this.pi.on('session_start', (event, ctx) =>
      this.guard(() => this.onSessionStart(ctx, event)),
    );
    this.pi.on('session_shutdown', () => this.guard(() => this.onSessionShutdown()));
    this.pi.on('message_update', (event) => this.guard(() => this.onMessageUpdate(event)));
    // Real pi's assistant-completion signal. `message_update` never carries a
    // `done`, so this is the only live source of the `message` payload.
    this.pi.on('message_end', (event) => this.guard(() => this.onMessageEnd(event)));
    // `/session-name` in the TUI emits `session_info_changed`; subscribing keeps
    // the phone's label current without waiting for the next prompt.
    this.pi.on('session_info_changed', () =>
      this.guard(() => this.refreshLabel(this.currentLabel())),
    );
    this.pi.on('agent_start', () =>
      this.guard(() => {
        // A new turn starts with no reply, so a settle before any assistant
        // message cannot inherit the previous turn's text.
        this.lastSettled = { text: '', truncated: false };
        this.setAgentState('running');
      }),
    );
    // Terminal state is `agent_settled`, deliberately not `agent_end`.
    this.pi.on('agent_settled', () =>
      this.guard(() => {
        // A settled turn has no in-flight calls, so anything still held is an
        // aborted call no result will ever consume.
        this.toolArgs.clear();
        this.setAgentState('settled');
        this.sendUsageEvent();
        this.sendSettleEvent();
      }),
    );
    // Compaction is an LLM summarization call, so without this the app sits
    // silent from the tap until it finishes. `session_before_compact` is the
    // only extension-visible "starting" signal: pi emits it ahead of the
    // summarization call from BOTH entry points, for all three reasons (manual,
    // threshold, overflow) — so an automatic compaction is announced too.
    // Registering a handler makes pi await it, so it stays cheap and returns
    // undefined, which pi reads as "no cancel, no custom compaction".
    this.pi.on('session_before_compact', () =>
      this.guard(() => this.sendCompactingEvent(true)),
    );
    // Compaction invalidates the token count — pi reports it as unknown until the
    // next model response — so the reading is re-taken rather than left stale.
    // Clearing the indicator in the same handler keeps the two from overlapping.
    this.pi.on('session_compact', () =>
      this.guard(() => {
        this.sendCompactingEvent(false);
        this.sendUsageEvent();
      }),
    );
    // Any effective thinking-level change: the app's own `setThinkingLevel`, a
    // PC-side `/thinking`, or a clamp during `setModel`. Re-reporting usage keeps
    // the level the menu shows current without waiting for the next turn.
    this.pi.on('thinking_level_select', () => this.guard(() => this.sendUsageEvent()));
    // A PC-side `/model` change: the app's model label must follow without
    // waiting for the next turn, exactly as the thinking level does. `setModel`
    // also re-baselines directly, because `_emitModelSelect` early-returns for
    // an equal-model switch and the direct emit is then the only frame.
    this.pi.on('model_select', () => this.guard(() => this.sendUsageEvent()));
    // A leaf move — the app's own tap or a PC-side `/tree` — is the one signal
    // that the branch changed. pi emits it after `branch()`/`resetLeaf()`, so a
    // re-requesting viewer re-baselines on the new branch. Guarded like every
    // other subscription so a mapping failure cannot escape into pi.
    this.pi.on('session_tree', (event) => this.guard(() => this.onSessionTree(event)));
    // `ctx.compact()` is fire-and-forget and passes no `onError`, so a failed
    // compaction is otherwise invisible. Surface every reason (manual, overflow,
    // threshold) — an auto-compaction failure is more consequential, not less.
    // pi emits this from the `catch` of both compaction paths, so the indicator
    // raised above is always cleared — including when the compaction was aborted
    // rather than failed.
    this.pi.on('session_compact_failed', (event) =>
      this.guard(() => {
        this.sendCompactingEvent(false);
        this.onCompactFailed(event);
      }),
    );
  }

  /**
   * Runs a callback so nothing can escape into pi or the WebSocket event loop.
   * A socket callback that throws is an uncaught exception: Node prints to
   * stderr and pi dies, which breaks the absolute silence guarantee. Failures
   * are surfaced only under debug.
   */
  private guard(run: () => void): void {
    try {
      run();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.debug('stderr', `pi-droid bridge: handler failed: ${message}\n`);
    }
  }

  private registerSessionCommand(): void {
    if (this.sessionCommandsRegistered) return;
    this.sessionCommandsRegistered = true;
    this.pi.registerCommand?.(SESSION_COMMAND_NAME, {
      description: 'Drive pi session actions from the pi-droid app',
      handler: (args, ctx) => this.onSessionCommand(args, ctx),
    });
  }

  /**
   * Runs inside a real pi command context. pi invalidates that context after
   * `newSession`/`fork`, so the handler performs exactly one action and returns;
   * any notice is emitted on the bridge's own socket, never on the context.
   */
  private async onSessionCommand(args: string, cmdCtx: BridgeCommandCtx): Promise<void> {
    const [action, target] = args.trim().split(/\s+/, 2);
    try {
      if (action === 'new') {
        const result = await cmdCtx.newSession();
        if (result.cancelled) this.sendStatusError('the new session was cancelled');
        return;
      }
      if (action === 'tree') {
        if (target === undefined) {
          this.sendStatusError('the tree target is missing');
          return;
        }
        const result = await cmdCtx.navigateTree(target);
        if (result.cancelled) this.sendStatusError('the tree navigation was cancelled');
        return;
      }
      if (action === 'fork') {
        if (target === undefined) {
          this.sendStatusError('the fork target is missing');
          return;
        }
        const result = await cmdCtx.fork(target);
        if (result.cancelled) this.sendStatusError('the fork was cancelled');
        return;
      }
      // An unknown action (empty or mistyped) must not fall through silently:
      // `dispatch` already acked `ok:true`, so the only signal the app gets is
      // this notice.
      this.sendStatusError(`unknown session action: ${action || '(empty)'}`);
      return;
    } catch (error) {
      // pi invalidates the context after `newSession`/`fork`, and this branch
      // never touches `cmdCtx` again — the notice goes out on the bridge's own
      // socket. A throw is surfaced, never left as an unhandled rejection.
      this.sendStatusError(error instanceof Error ? error.message : String(error));
    }
  }

  /** Emits a notice the app renders in the transcript. */
  private sendStatusError(message: string): void {
    this.sendEvent({ kind: 'status', event: 'error', message });
  }

  private onSessionStart(ctx: BridgeCtx, event: unknown): void {
    const reason =
      typeof event === 'object' && event !== null
        ? (event as { reason?: unknown }).reason
        : undefined;
    const sessionId = ctx.sessionManager.getSessionId();
    // A replacement (`/new`, `/fork`, `/resume`) re-fires `session_start` under
    // a new id; the successor's register names the id it replaced so the app can
    // follow it instead of treating the new id as an unrelated session. `/resume`
    // can reload the same id, so "differs" is part of the condition.
    if (
      (reason === 'new' || reason === 'fork' || reason === 'resume') &&
      lastRegisteredSessionId !== null &&
      lastRegisteredSessionId !== sessionId
    ) {
      this.replacesSessionId = lastRegisteredSessionId;
    }
    lastRegisteredSessionId = sessionId;
    // Session replacement invalidates the previous context: drop the old
    // socket and every session-scoped value before binding the new context.
    this.closeSocket('session replaced');
    this.cancelReconnect();
    this.ctx = ctx;
    this.closed = false;
    this.seq = 0;
    this.state = 'idle';
    this.lastSettled = { text: '', truncated: false };
    this.attempt = 0;
    // Only calls with no recorded result can still be in flight: a call whose
    // `toolResult` is already in the entries can never produce another, so
    // seeding it would retain its arguments for the session. `reload` is the
    // reason that can strand an unpaired call across an instance boundary.
    this.toolArgs.clear();
    try {
      for (const [id, args] of collectUnpairedToolArgs(ctx.sessionManager.getEntries())) {
        this.toolArgs.set(id, args);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.debug('stderr', `pi-droid bridge: tool-arg seeding failed: ${message}\n`);
    }
    if (!isActiveMode(ctx.mode)) {
      this.debug('stderr', `pi-droid bridge: inert in ${ctx.mode} mode\n`);
      return;
    }
    this.openSocket();
  }

  private onSessionShutdown(): void {
    this.closed = true;
    this.ctx = null;
    this.cancelReconnect();
    this.closeSocket('shutdown');
  }

  private closeSocket(reason: string): void {
    const socket = this.socket;
    this.socket = null;
    if (socket === null) return;
    try {
      socket.close(1000, reason);
    } catch {
      // Already closed; nothing to do.
    }
  }

  private cancelReconnect(): void {
    if (this.reconnectTimer === null) return;
    this.deps.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
  }

  private openSocket(): void {
    const endpoint = this.deps.resolveEndpoint();
    if (endpoint === null) {
      this.debug('stderr', 'pi-droid bridge: no hub discovered\n');
      this.scheduleReconnect();
      return;
    }
    const socket = this.deps.socketFactory(endpoint.url);
    this.socket = socket;
    socket.addEventListener('open', () =>
      this.guard(() => {
        if (this.socket !== socket) return;
        this.attempt = 0;
        this.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: endpoint.token });
        this.sendRegister(this.currentLabel());
        this.sendAgentState();
      }),
    );
    socket.addEventListener('message', (event) => this.guard(() => this.onMessage(event)));
    socket.addEventListener('error', () =>
      this.guard(() => this.debug('stderr', 'pi-droid bridge: socket error\n')),
    );
    socket.addEventListener('close', (event) => this.guard(() => this.onSocketClose(socket, event)));
  }

  private onSocketClose(socket: BridgeSocket, event: BridgeCloseEvent): void {
    if (this.socket !== socket) return;
    this.socket = null;
    const code = event.code;
    this.debug('stderr', `pi-droid bridge: socket closed (${String(code ?? 'transport')})\n`);
    // 4003 is a capability violation: a bridge bug, not a transient failure.
    // Retrying it at capped backoff would reconnect forever.
    if (code === 4003) return;
    // 4002 is a protocol violation — a version mismatch, malformed JSON, a missing
    // field, or an unhandled type. All are permanent producer bugs (whose side is
    // not knowable here): a retry reconnects to the same rejection forever. Stop,
    // and say why. CLOSE_INTERNAL (4500) is deliberately NOT included: that close
    // is transient and must retry.
    if (code === 4002) {
      this.debug('stderr', 'pi-droid bridge: protocol close 4002; not reconnecting\n');
      return;
    }
    // 4008 is rate-limited: the hub delayed the close deliberately, so wait a
    // longer fixed span rather than an ordinary jittered backoff step.
    if (code === 4008) {
      this.scheduleReconnect(RATE_LIMITED_RECONNECT_MS);
      return;
    }
    this.scheduleReconnect();
  }

  private scheduleReconnect(fixedDelayMs?: number): void {
    if (this.closed) return;
    // A pending timer already owns the next dial; scheduling a second would
    // leak the first and double-connect.
    if (this.reconnectTimer !== null) return;
    const delay = fixedDelayMs ?? computeBackoff(this.attempt, { rng: this.deps.rng });
    if (fixedDelayMs === undefined) this.attempt += 1;
    this.reconnectTimer = this.deps.setTimeout(() => {
      this.reconnectTimer = null;
      this.openSocket();
    }, delay);
  }

  private send(message: AgentToHubMessage): boolean {
    if (this.socket === null || this.socket.readyState !== SOCKET_OPEN) return false;
    this.socket.send(encodeAgentMessage(message));
    return true;
  }

  private sendEvent(payload: EventPayload): void {
    const message: EventMessage = { protocolVersion: PROTOCOL_VERSION, type: 'event', payload };
    this.send(message);
  }

  private sendRegister(label: string | null): void {
    const ctx = this.ctx;
    if (ctx === null) return;
    const manager = ctx.sessionManager;
    const message: RegisterMessage = {
      protocolVersion: PROTOCOL_VERSION,
      type: 'register',
      sessionId: manager.getSessionId(),
      sessionFile: manager.getSessionFile(),
      cwd: ctx.cwd,
      mode: ctx.mode,
      pid: process.pid,
    };
    if (ctx.model !== undefined) message.model = ctx.model.id;
    if (ctx.thinkingLevel !== undefined) message.thinkingLevel = ctx.thinkingLevel;
    if (label !== null) message.name = label;
    const replaces = this.replacesSessionId;
    if (replaces !== null) message.replaces = replaces;
    this.lastLabel = label;
    if (this.send(message) && replaces !== null) {
      // Consumed only by a register that actually reached the wire: a dropped
      // register never told the hub, so the linkage must survive for the next
      // real one.
      this.replacesSessionId = null;
    }
  }

  /**
   * The session's label: pi's explicit name, else the caller's fallback
   * (entries at register, the event's own message live). One try/catch covers
   * both reads so a throwing `getSessionName` or `getEntries` degrades to "no
   * label" — the hub's basename fallback — rather than costing registration.
   */
  private resolveLabel(fallback: () => string | null): string | null {
    try {
      return sanitizeLabel(this.pi.getSessionName?.()) ?? fallback();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.debug('stderr', `pi-droid bridge: label resolution failed: ${message}\n`);
      return null;
    }
  }

  private currentLabel(): string | null {
    const ctx = this.ctx;
    if (ctx === null) return null;
    return this.resolveLabel(() => labelFromEntries(ctx.sessionManager.getEntries()));
  }

  private refreshLabel(label: string | null): void {
    if (label === null || label === this.lastLabel) return;
    this.sendRegister(label);
  }

  private sendAgentState(): void {
    this.sendEvent({ kind: 'agent', state: this.state });
  }

  private setAgentState(state: AgentState): void {
    this.state = state;
    this.sendEvent({ kind: 'agent', state });
  }

  private onMessageUpdate(event: unknown): void {
    const assistantEvent = (event as { assistantMessageEvent?: AssistantMessageEvent })
      .assistantMessageEvent;
    if (assistantEvent === undefined) return;
    const candidate = this.seq + 1;
    const normalized = normalizeAssistantEvent(assistantEvent, candidate);
    if (normalized.kind === 'ignore') return;
    if (normalized.payload.kind === 'stream') this.seq = candidate;
    this.sendEvent(normalized.payload);
  }

  private onMessageEnd(event: unknown): void {
    const normalized = normalizeMessageEnd(event as MessageEndEvent);
    if (normalized.kind === 'ignore') return;
    this.sendEvent(normalized.payload);
    // A tool call/result follows its own message frame, so the app can pair the
    // normalized view with the row the message produced.
    const original = (event as { message?: unknown }).message;
    const originalRole =
      typeof original === 'object' && original !== null
        ? (original as { role?: unknown }).role
        : undefined;
    if (originalRole === 'assistant') {
      for (const payload of toolCallPayloads(original, this.toolArgs)) {
        this.sendEvent(boundToolPayload(payload));
      }
      for (const [id, args] of collectToolArgs([original])) this.toolArgs.set(id, args);
    } else if (originalRole === 'toolResult') {
      const payload = toolResultPayload(original, this.toolArgs);
      // Delete before the send: the result is the only reader that needs the
      // arguments, and a throw out of `sendEvent` must not skip the release.
      const toolCallId = asString((original as { toolCallId?: unknown }).toolCallId);
      if (toolCallId !== null) this.toolArgs.delete(toolCallId);
      if (payload !== null) this.sendEvent(boundToolPayload(payload));
    }
    // The snippet comes from the ORIGINAL message, never the bounded payload:
    // an oversized reply is replaced by a `{truncated:true,bytes}` marker, and
    // caching that marker would make every huge reply notify `'No reply'`.
    if (originalRole === 'assistant') {
      this.lastSettled = settleText(
        messageText((original as { content?: unknown }).content),
        SETTLED_TEXT_MAX_CODE_POINTS,
      );
    }
    // The live path uses the event's own message, never the entries scan: pi
    // persists the message only after this event, so `getEntries()` is stale.
    this.refreshLabel(
      this.resolveLabel(() => labelFromMessage((event as { message?: unknown }).message)),
    );
  }

  private onMessage(event: unknown): void {
    const data = (event as { data?: unknown }).data;
    if (typeof data !== 'string') return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(data);
    } catch {
      return;
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return;
    const message = parsed as Record<string, unknown>;
    if (message.protocolVersion !== PROTOCOL_VERSION) return;
    if (message.type === 'command') this.onCommand(message);
    else if (message.type === 'history-request') this.sendHistory(asString(message.cursor) ?? undefined);
  }

  private onCommand(message: Record<string, unknown>): void {
    const command = parseCommand(message);
    if (command === null) return;
    void this.dispatch(command);
  }

  private async dispatch(command: CommandMessage): Promise<void> {
    try {
      if (!COMMAND_ALLOWLIST.has(command.name)) {
        this.sendCommandResult(command.id, false, COMMAND_NOT_ALLOWED);
        return;
      }
      const ctx = this.ctx;
      if (ctx === null) {
        this.sendCommandResult(command.id, false, 'no active session');
        return;
      }
      // Re-checked here so a future socket path cannot dispatch in an inert
      // mode, and the session is verified rather than trusted to hub routing.
      if (!isActiveMode(ctx.mode)) {
        this.sendCommandResult(command.id, false, 'bridge inactive in this mode');
        return;
      }
      if (command.sessionId !== ctx.sessionManager.getSessionId()) {
        this.sendCommandResult(command.id, false, 'session mismatch');
        return;
      }
      if (command.name === 'fetchHistory') {
        this.sendHistory();
        this.sendCommandResult(command.id, true);
        return;
      }
      const outcome = await this.dispatchCommand(ctx, command.name, command.args);
      this.sendCommandResult(
        command.id,
        outcome.ok,
        outcome.error,
        outcome.commands,
        outcome.queued,
        outcome.models,
        outcome.tree,
        outcome.treeTruncated,
        outcome.leafId,
      );
    } catch (error) {
      this.sendCommandResult(
        command.id,
        false,
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  private async dispatchCommand(
    ctx: BridgeCtx,
    name: string,
    args: unknown,
  ): Promise<CommandOutcome> {
    const fields = asObject(args) ?? {};
    switch (name) {
      case 'prompt':
      case 'steer':
      case 'followup': {
        const text = asString(fields.text);
        if (text === null) return { ok: false, error: 'missing text' };
        const imagesResult = parseImages(fields.images);
        if (!imagesResult.ok) return { ok: false, error: 'malformed images' };
        const content: UserMessageContent =
          imagesResult.images === undefined
            ? text
            : [{ type: 'text', text }, ...imagesResult.images];
        // `steer` and `followup` name their mode explicitly. For a plain
        // `prompt` the mode is the agent's: the app cannot make this call well
        // because its agent state is a network round-trip stale, so a stale
        // "idle" would reproduce the silent mid-turn drop. Read `isIdle()`
        // here instead: idle → today's plain prompt; running → steer, mirroring
        // the TUI's Enter (interactive-mode.js:2615). The check is once, at
        // dispatch: pi re-reads `isStreaming` after its own preflight, so the
        // guarantee is "never worse than today", not race-free. Steer-on-idle
        // is benign — pi ignores `streamingBehavior` when not streaming.
        let deliverAs: 'steer' | 'followUp' | undefined;
        // Only the automatic branch reports `queued`: explicit `steer`/`followup`
        // name their mode, so they are not the bridge deciding to queue a plain
        // prompt mid-turn. `false` is never emitted — absent is the default.
        let queued = false;
        if (name === 'steer') {
          deliverAs = 'steer';
        } else if (name === 'followup') {
          deliverAs = 'followUp';
        } else {
          deliverAs = ctx.isIdle() ? undefined : 'steer';
          queued = deliverAs === 'steer';
        }
        // `expandPromptTemplates` is what makes `/name` a command. pi's
        // extension API defaults it to FALSE, which injects the text verbatim
        // and leaves the model to read a command name as prose; pi's own
        // interactive path defaults it to true. Opting in is also what expands
        // `/skill:name`, and matches pi's steer, which expands templates too.
        this.pi.sendUserMessage(content, {
          expandPromptTemplates: true,
          ...(deliverAs === undefined ? {} : { deliverAs }),
        });
        return queued ? { ok: true, queued: true } : { ok: true };
      }
      case 'abort':
        ctx.abort();
        return { ok: true };
      case 'setModel': {
        // pi's AgentSession.setModel has no streaming guard: mid-turn it mutates
        // agent.state.model under the in-flight call and cascades a thinking-level
        // clamp. The phone cannot see streaming state, so refuse visibly rather
        // than put the session on a mixed-model turn. Best-effort: isIdle() is
        // read here with no await before setModel.
        if (!ctx.isIdle()) return { ok: false, error: 'cannot switch the model while pi is working' };
        const provider = asString(fields.provider);
        const id = asString(fields.id);
        if (provider === null || id === null) return { ok: false, error: 'missing model' };
        const registry = ctx.modelRegistry;
        if (registry === undefined || typeof registry.find !== 'function') {
          return { ok: false, error: 'models unavailable' };
        }
        const model = registry.find(provider, id);
        if (model === undefined || model === null) return { ok: false, error: 'model not found' };
        const accepted = await this.pi.setModel(model);
        // Kept even though `model_select` also re-reports: `_emitModelSelect`
        // early-returns for an equal model, so a same-model switch would emit
        // nothing. A duplicate on a real switch is harmless and idempotent.
        if (accepted) this.sendUsageEvent();
        return accepted ? { ok: true } : { ok: false, error: 'model not accepted' };
      }
      case 'setThinkingLevel': {
        const level = asString(fields.level);
        if (level === null) return { ok: false, error: 'missing level' };
        this.pi.setThinkingLevel(level);
        return { ok: true };
      }
      case 'compact':
        ctx.compact();
        return { ok: true };
      case 'listCommands': {
        const raw = this.pi.getCommands?.();
        if (raw === undefined || !Array.isArray(raw)) {
          return { ok: false, error: 'commands unavailable' };
        }
        const commands: SlashCommand[] = [];
        for (const entry of raw) {
          const name = asString((entry as { name?: unknown })?.name);
          if (name === null) continue;
          // Hide the bridge's own command: the bare name and pi's `:N` duplicate
          // form. A `pi-droid-session-foo` tail is a different, real command.
          if (name === SESSION_COMMAND_NAME || name.startsWith(`${SESSION_COMMAND_NAME}:`)) {
            continue;
          }
          const command: SlashCommand = { name };
          const description = asString((entry as { description?: unknown })?.description);
          if (description !== null) command.description = description;
          commands.push(command);
        }
        return { ok: true, commands };
      }
      case 'listModels': {
        const registry = ctx.modelRegistry;
        if (registry === undefined || typeof registry.getAvailable !== 'function') {
          return { ok: false, error: 'models unavailable' };
        }
        const raw = registry.getAvailable();
        if (!Array.isArray(raw)) return { ok: false, error: 'models unavailable' };
        const models: ModelSummary[] = [];
        for (const entry of raw) {
          const model = projectModel(entry);
          if (model !== null) models.push(model);
        }
        return { ok: true, models };
      }
      case 'listTree': {
        const manager = ctx.sessionManager;
        if (typeof manager.getTree !== 'function') {
          return { ok: false, error: 'tree unavailable' };
        }
        const projection = projectTree(manager.getTree(), TREE_MAX_NODES);
        const leafId = typeof manager.getLeafId === 'function' ? manager.getLeafId() : null;
        return {
          ok: true,
          tree: projection.nodes,
          treeTruncated: projection.truncated,
          leafId,
        };
      }
      case 'setSessionName': {
        const sessionName = asString(fields.name);
        if (sessionName === null) return { ok: false, error: 'missing name' };
        this.pi.setSessionName(sessionName);
        // Read the (possibly normalized) name back: a rename is a label change
        // even when it was made elsewhere.
        this.refreshLabel(this.currentLabel());
        return { ok: true };
      }
      case 'sessionNew':
        return this.triggerSessionAction('new');
      case 'sessionTree': {
        // `navigateTree` is in place but throws on a streaming/compacting
        // session, so refuse synchronously rather than let pi throw later.
        if (!ctx.isIdle()) {
          return { ok: false, error: 'cannot navigate the tree while pi is working' };
        }
        const entryId = asString(fields.entryId);
        if (entryId === null) return { ok: false, error: 'missing entry' };
        // Validate the target here, at dispatch, exactly as `sessionFork` does:
        // `triggerSessionAction` only acks that pi accepted the request, and a
        // stale id would then surface as a `status/error` long after the app
        // moved on. pi resolves non-message entries too (the leaf becomes the
        // entry), so only resolution is required, not a role.
        if (asObject(ctx.sessionManager.getEntry(entryId)) === null) {
          return { ok: false, error: 'unknown entry' };
        }
        return this.triggerSessionAction('tree', entryId);
      }
      case 'sessionFork': {
        const entryId = asString(fields.entryId);
        if (entryId === null) return { ok: false, error: 'missing entry' };
        // Validate the target here, at dispatch: an entry can be invalidated by
        // a turn landing between the app listing the tree and tapping a node.
        const entry = asObject(ctx.sessionManager.getEntry(entryId));
        const message = entry === null ? null : asObject(entry.message);
        // The target must be a *message* entry with role `user` (pi's default
        // `position:'before'` fork requirement). A non-message entry that merely
        // carries a `message` object must be refused here, at dispatch — not
        // later as a status error after `ok:true` was already acked.
        if (entry?.type !== 'message' || message === null || message.role !== 'user') {
          return { ok: false, error: 'unknown entry' };
        }
        return this.triggerSessionAction('fork', entryId);
      }
      default:
        return { ok: false, error: COMMAND_NOT_ALLOWED };
    }
  }

  /**
   * Triggers the bridge's own registered command — the only route to a real
   * command context. Fire-and-forget, exactly like `sendUserMessage`; the
   * replacement itself (or a status notice) is what confirms the outcome.
   */
  private triggerSessionAction(action: string, target?: string): CommandOutcome {
    const text =
      target === undefined
        ? `/${SESSION_COMMAND_NAME} ${action}`
        : `/${SESSION_COMMAND_NAME} ${action} ${target}`;
    this.pi.sendUserMessage(text, { expandPromptTemplates: true });
    return { ok: true };
  }

  private sendHistory(cursor?: string): void {
    const ctx = this.ctx;
    if (ctx === null) return;
    // The snapshot carries the same normalized tool views as the live relay, so
    // a reconnecting or history-loading viewer does not need to re-derive them.
    // The projection is the ACTIVE BRANCH (`buildContextEntries`), not the whole
    // file: navigating the tree only moves a leaf, so a whole-file replay would
    // never change. Fall back to `getEntries()` on an older pi that lacks it.
    const manager = ctx.sessionManager;
    const entries =
      typeof manager.buildContextEntries === 'function'
        ? manager.buildContextEntries()
        : manager.getEntries();
    const annotated = annotateToolViews(entries);
    const requested = cursor ?? null;
    // Honour the cursor only when the anchor digests the ORIGINAL entry at the
    // offset (never a collapsed marker) and the offset is in range; anything
    // else degrades to a fresh newest page, never an error.
    const parsed = requested === null ? null : parseHistoryCursor(requested);
    const honoured =
      parsed !== null &&
      parsed.offset < annotated.length &&
      entryAnchor(parsed.offset, annotated[parsed.offset]) === parsed.anchor;
    const page = honoured
      ? projectHistory(annotated, HISTORY_MAX_BYTES, parsed!.offset)
      : projectHistory(annotated, HISTORY_MAX_BYTES);
    const message: HistoryMessage = {
      protocolVersion: PROTOCOL_VERSION,
      type: 'history',
      sessionId: ctx.sessionManager.getSessionId(),
      entries: page.entries,
      truncated: page.truncated,
      // The routing token is echoed whenever the request had one, honoured or
      // not; `older` is present only when the page is genuinely older, and the
      // next cursor only while older entries remain.
      ...(requested !== null ? { cursor: requested } : {}),
      ...(honoured ? { older: true } : {}),
      ...(page.start > 0 ? { olderCursor: mintCursor(annotated, page.start) } : {}),
    };
    this.send(message);
    // After the history frame, so a viewer that re-baselines on the snapshot
    // cannot overwrite the fresh reading with an older one. A phone attaching
    // mid-session lands here, which is why the reading rides the replay rather
    // than the register frame: at register the hub has no subscribers yet.
    this.sendUsageEvent();
  }

  /**
   * Sends the current context usage, if pi can report one. A missing reading is
   * silence, never an error: this is ambient information, and it must not be
   * able to break the transcript it decorates.
   */
  private sendUsageEvent(): void {
    const ctx = this.ctx;
    if (ctx === null) return;
    let usage: { tokens: number | null; contextWindow: number } | null;
    try {
      usage = readContextUsage(ctx);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.debug('stderr', `pi-droid bridge: context usage failed: ${message}\n`);
      return;
    }
    if (usage === null) return;
    const payload: ContextUsagePayload = {
      kind: 'usage',
      tokens: usage.tokens,
      contextWindow: usage.contextWindow,
    };
    const level = ctx.thinkingLevel;
    if (typeof level === 'string') payload.thinkingLevel = level;
    const model = projectModel(ctx.model);
    if (model !== null) payload.model = model;
    this.sendEvent(payload);
  }

  /**
   * Announces that a compaction is running, so the app can show it rather than
   * sitting silent through a summarization call.
   *
   * Rides a `status` payload — an existing kind, so no new frame type and no hub
   * restart. This is the one status the app reads as transient state rather than
   * as a transcript notice, so it deliberately carries no `message`: a notice is
   * a row, and a row would outlive the compaction it describes.
   *
   * Paired by construction: every `session_before_compact` is followed by
   * exactly one of `session_compact` or `session_compact_failed`, and both
   * clear it. A hard-killed pi is the one way to leave it stuck. The one
   * theoretical hole is that pi gates the success emit on re-finding the
   * compaction entry it just appended, so a missed lookup would return success
   * having emitted neither — unreachable in practice, recorded so it is not
   * mistaken for a bug if it ever shows up.
   */
  private sendCompactingEvent(active: boolean): void {
    this.sendEvent({ kind: 'status', event: 'compacting', active });
  }

  /**
   * Surfaces a failed compaction as an error notice. Gated on a non-empty
   * `errorMessage`, which also excludes a deliberately aborted compaction (pi
   * leaves `errorMessage` undefined for those). No `reason` filter: manual,
   * overflow and threshold failures are all reported.
   */
  private onCompactFailed(event: unknown): void {
    const errorMessage =
      typeof event === 'object' && event !== null
        ? (event as { errorMessage?: unknown }).errorMessage
        : undefined;
    if (typeof errorMessage !== 'string' || errorMessage.length === 0) return;
    this.sendEvent({ kind: 'status', event: 'error', message: errorMessage });
  }

  /** Emits the cached turn snippet, after the terminal state and usage. */
  private sendSettleEvent(): void {
    this.sendEvent({
      kind: 'settled',
      text: this.lastSettled.text,
      truncated: this.lastSettled.truncated,
    });
  }

  /**
   * Maps pi's `session_tree` event to the `leaf` payload. A `null` `newLeafId`
   * (navigated to the root) is preserved, not omitted: absent means "an older
   * bridge", which the app cannot tell from "at the root".
   */
  private onSessionTree(event: unknown): void {
    const raw = (event as { newLeafId?: unknown } | null)?.newLeafId;
    const leafId = typeof raw === 'string' && raw.length > 0 ? raw : null;
    this.sendEvent({ kind: 'leaf', leafId });
  }

  private sendCommandResult(
    id: string,
    ok: boolean,
    error?: string,
    commands?: SlashCommand[],
    queued?: boolean,
    models?: ModelSummary[],
    tree?: TreeNodeSummary[],
    treeTruncated?: boolean,
    leafId?: string | null,
  ): void {
    const message: CommandResultMessage = {
      protocolVersion: PROTOCOL_VERSION,
      type: 'command-result',
      id,
      ok,
    };
    if (error !== undefined) message.error = error;
    if (commands !== undefined) message.commands = commands;
    if (queued !== undefined) message.queued = queued;
    if (models !== undefined) message.models = models;
    if (tree !== undefined) message.tree = tree;
    if (treeTruncated !== undefined) message.treeTruncated = treeTruncated;
    if (leafId !== undefined) message.leafId = leafId;
    this.send(message);
  }
}

/**
 * Installs the bridge on a pi `ExtensionAPI`. Side-effectful by design: it
 * registers handlers and returns nothing. Tests call this directly with
 * injected dependencies; pi calls the default export with its own API.
 */
export function installBridge(pi: BridgePi, deps: BridgeDeps = {}): void {
  new Bridge(pi, resolveDeps(deps)).install();
}

/** The extension entry point pi loads. */
export default function piDroidBridge(pi: BridgePi): void {
  installBridge(pi);
}
