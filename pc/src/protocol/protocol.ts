/**
 * The attach-protocol envelope and codec.
 *
 * Pure: no I/O, no clock, no randomness. Types are JSON-encodable and use
 * only erasable syntax (no `enum`, `namespace`, or parameter properties).
 *
 * `encode` trusts its typed input; `decode` is the validating boundary.
 * "Never throws" is a `decode`-only guarantee: it catches the `SyntaxError`
 * from malformed JSON and any `RangeError` JSON.parse raises on pathological input.
 */

export const PROTOCOL_VERSION = 1;

/**
 * The shared byte cap for one agent-supplied bulk payload: the bridge bounds the
 * final `done`/`message_end` message to this, and the hub uses it as the default
 * per-viewer relay budget. History uses `HISTORY_MAX_BYTES` instead — depth and
 * per-frame safety are different jobs that must not share a number.
 */
export const MAX_RELAY_BYTES = 256 * 1024;

/**
 * The byte cap for one normalized tool view payload. This exists because a
 * relayed frame is dropped **whole** whenever any byte is outstanding on the
 * viewer (`backpressure.ts` `admit` rejects on `queued + bytes > cap`, and the
 * hub's cap defaults to `MAX_RELAY_BYTES`). A payload bounded at the budget
 * itself is therefore dropped under any backlog; a quarter of it only under a
 * severe backlog, and the unbudgeted `resync-required` → `snapshot` path
 * recovers a dropped one (collapsed). Deliberately a fraction of
 * `MAX_RELAY_BYTES`, never equal to it.
 */
export const TOOL_VIEW_MAX_BYTES = 64 * 1024;

/**
 * The bridge's history *page* size: the byte budget for the newest entries a
 * baseline returns, and likewise for each older page requested with a cursor.
 * Older entries are not unreachable — the app asks for one page at a time via
 * `cursor`/`olderCursor`. A `snapshot` answering a `history-request` is a
 * control *response* the viewer asked for, delivered unbudgeted, so its only
 * hard ceiling is the hub's 1 MiB frame cap. Deliberately larger than
 * `MAX_RELAY_BYTES`: that one sizes a single relayed message, this one sizes a
 * page, and sharing one number between the two jobs hid everything but the
 * oldest 256 KB of a long session.
 */
export const HISTORY_MAX_BYTES = 768 * 1024;

/**
 * The wire protocol, in one place.
 *
 * A Dart port works from this block alone.
 *
 * ## Close codes (WebSocket application range 4000-4999)
 * - `4002` capability/protocol violation: a message a listener does not permit,
 *   a non-`hello` message before authentication, a bad `protocolVersion`,
 *   malformed JSON, a missing required field, or a permitted type with no
 *   dispatch branch (the hub fails closed).
 * - `4003` a listener-bound capability violation for a message this listener
 *   does not permit (see `hub.ts`, the enforcement site).
 * - `4008` rate limited: the per-connection failed-credential cap was reached.
 *   It arrives **after a short delay** (~250 ms), deliberately, so a socket
 *   cannot be used as a fast token oracle. Treat it as "wait, then retry", not
 *   as a transport failure.
 * - `4500` an unexpected internal handler error, contained to one connection;
 *   retryable — this is a transient fault, not a capability or protocol bug.
 *
 * ## Envelope
 * Every message is one JSON object with `protocolVersion` and `type`.
 *
 * agent -> hub (loopback listener):
 * - `hello`  { ticket XOR token }
 * - `register` { sessionId, sessionFile?, cwd?, name?, model?, thinkingLevel?, mode?, pid?, replaces? }
 * - `event`  { payload: stream | message | agent | tool | status | usage | settled | leaf }
 * - `history` { sessionId, entries: unknown[], truncated: boolean, cursor?, older?, olderCursor? }
 * - `command-result` { id, ok, error?, commands?, models?, queued?, tree?, treeTruncated?, leafId? }
 *
 * viewer -> hub (LAN listener):
 * - `hello`  { ticket XOR token }
 * - `subscribe` / `unsubscribe` { sessionId }
 * - `history-request` { sessionId, sinceSeq?, cursor? }
 * - `command` { id, sessionId, name, args? }
 *
 * hub -> viewer:
 * - `paired` { token } — sent once, on a successful ticket exchange; this is
 *   the only message that carries the token.
 * - `sessions` { sessions: [ { sessionId, label, agentState } ] } — the
 *   registry as a summary, pushed on authentication and whenever the registry
 *   changes: a register/takeover, a session retirement, or an agent-state
 *   transition. A stream delta does not push it. `lastSeq` is deliberately not
 *   part of a summary — it moves on every stream delta; a viewer that needs a
 *   watermark asks for a `snapshot`. An empty list is a real value (there are
 *   no sessions), not an absence.
 * - `event` { payload } — routed normalized events.
 * - `agent-settled` { sessionId, label, text, truncated } — a session settled;
 *   broadcast to every authenticated viewer (not subscriber-scoped), because the
 *   phone must be able to notify for a session it is not viewing.
 * - `snapshot` { sessionId, lastSeq, agentState, entries: unknown[], truncated, cursor?, older?, olderCursor? }
 *   — `lastSeq`/`agentState` are hub-tracked; `entries` are agent-supplied and
 *   may be truncated.
 * - `command-result` { id, ok, error?, commands?, models?, queued?, tree?, treeTruncated?, leafId? }
 * - `resync-required` { sessionId, reason }
 * - `session-gone` { sessionId }
 *
 * hub -> agent:
 * - `command` (forwarded verbatim, including `id`)
 * - `history-request` { sessionId, sinceSeq?, cursor? }
 *
 * `cursor`/`older`/`olderCursor` on a `history` or `snapshot` are split by role.
 * `cursor` echoes the request's cursor verbatim as a routing token and is
 * present whenever the request had one, whether or not it was honoured; `older`
 * is present and `true` only when the bridge genuinely paged, and the app
 * prepends only then; `olderCursor` is present iff older entries remain. A
 * request without a cursor (including `fetchHistory`) yields none of the three.
 * Both decoders ignore unknown fields, so a peer that predates these fields
 * decodes the frame as if they were absent.
 */

/** Fields shared by both `hello` credential shapes. */
export interface HelloBase {
  protocolVersion: number;
  type: 'hello';
}

/** Handshake: a viewer/agent proves itself with a ticket *or* a token, never both. */
export type HelloMessage =
  | (HelloBase & { ticket: string })
  | (HelloBase & { token: string });

/** The agent's reported lifecycle state. */
export const AGENT_STATES = ['idle', 'running', 'settled'] as const;
export type AgentState = (typeof AGENT_STATES)[number];

/**
 * Who started a session: the app (`app`) or the PC (`pc`). Derived hub-side
 * from the spawner's live children, never from a client claim.
 */
export const SESSION_ORIGINS = ['app', 'pc'] as const;
export type SessionOrigin = (typeof SESSION_ORIGINS)[number];

/** The normalized payload kinds an `event` may carry. */
export const EVENT_PAYLOAD_KINDS = ['stream', 'message', 'agent', 'tool', 'status', 'usage', 'settled', 'leaf'] as const;
export type EventPayloadKind = (typeof EVENT_PAYLOAD_KINDS)[number];

/** A token-stream delta, ordered by `seq`. Carried inside an `event`. A frame
 * carries `text` and/or `phase`; at least one is required. */
export interface StreamPayload {
  kind: 'stream';
  seq: number;
  text?: string;
  phase?: StreamPhase;
}

/**
 * Lifecycle phases a `stream` frame may signal, and the tag that marks one.
 *
 * `thinking` is emitted twice over: on `thinking_start` as a content-free
 * liveness signal (the frame carries no `text`), then on every
 * `thinking_delta` with that chunk in `text`. A frame carries `text` and/or
 * `phase`; at least one is required. The committed `message` stays
 * authoritative — it is what the transcript renders the durable reasoning
 * block from, and what replaces the streamed one.
 */
export const STREAM_PHASES = ['thinking'] as const;
export type StreamPhase = (typeof STREAM_PHASES)[number];

/**
 * The agent's context-usage reading, sampled at turn boundaries. `tokens` is an
 * estimate and is `null` right after a compaction, until the next model response
 * gives pi something to measure; `contextWindow` is the model's window. The
 * percentage is deliberately absent — it is exactly `tokens / contextWindow`,
 * and the app derives it rather than trusting a second source of truth.
 * `thinkingLevel` is the level in effect when the reading was taken (pi's
 * `ThinkingLevel`); it is optional so an older pi without a level omits it.
 * `model` is the session's current model when the reading was taken; it is
 * optional so an older pi without one omits the field.
 */
export interface ContextUsagePayload {
  kind: 'usage';
  tokens: number | null;
  contextWindow: number;
  thinkingLevel?: string;
  model?: ModelSummary;
}

/** The agent's lifecycle transition. Carried inside an `event`. */
export interface AgentPayload {
  kind: 'agent';
  state: AgentState;
}

/**
 * A session settled: the bridge's snippet of the turn's final assistant text.
 * `text` may be empty (a turn with no assistant message); `truncated` is true
 * when the bridge's code-point cap cut it. The hub relays this to every
 * authenticated viewer as an `agent-settled` message.
 */
export interface SettledPayload {
  kind: 'settled';
  text: string;
  truncated: boolean;
}

/**
 * The session tree's current leaf moved. `leafId` is the new leaf, or `null`
 * when the tree was navigated back to the root. Emitted by the bridge from its
 * `session_tree` subscription; the app re-requests history on it.
 */
export interface LeafPayload {
  kind: 'leaf';
  leafId: string | null;
}

/**
 * The normalized `tool` payload the bridge emits and the app renders by
 * `view.type`. `view` is optional and carried through unvalidated: a frame
 * lacking it (or carrying a `view.type` the app does not know) must still
 * decode and render via the app's generic fallback, so the decoder validates
 * only the identity/status fields. The pre-#6 shape (no `toolCallId`) is
 * rejected `bad-field` — no live producer ever emitted it.
 */
export const TOOL_STATUSES = ['running', 'done', 'error'] as const;
export type ToolStatus = (typeof TOOL_STATUSES)[number];

/** One line of a [DiffView]; `add`/`del` are additions/removals, `ctx` neither. */
export interface DiffLine {
  kind: 'add' | 'del' | 'ctx';
  text: string;
}

/** A unified diff, used by `edit` (real diff) and `write` (all additions). */
export interface DiffView {
  type: 'diff';
  path: string;
  lines: DiffLine[];
  truncated?: boolean;
}

/** A file's text content, optionally a line range (`read`). */
export interface FileView {
  type: 'file';
  path: string;
  content: string;
  startLine?: number;
  endLine?: number;
  truncated?: boolean;
}

/** A shell command and its merged output (`bash`); `exitCode` is best-effort. */
export interface CommandView {
  type: 'command';
  command: string;
  output: string;
  exitCode?: number;
  truncated?: boolean;
}

/** One search hit, flattened so the app can group by `file`. */
export interface Match {
  file: string;
  line: number;
  text: string;
}

/** Search hits (`grep`); an empty array is a real "no matches" value. */
export interface MatchesView {
  type: 'matches';
  matches: Match[];
  truncated?: boolean;
}

/** A tabular result (`ls`); an empty `rows` is a real "empty directory" value. */
export interface TableView {
  type: 'table';
  columns: string[];
  rows: string[][];
  truncated?: boolean;
}

/** The fallback shape for any tool without a structured view. */
export interface GenericView {
  type: 'generic';
  target?: string;
  truncated?: boolean;
}

export type ToolView =
  | DiffView
  | FileView
  | CommandView
  | MatchesView
  | TableView
  | GenericView;

export interface ToolPayload {
  kind: 'tool';
  toolCallId: string;
  name: string;
  status: ToolStatus;
  view?: ToolView;
}

/**
 * The remaining normalized kinds (`message`, `status`) are opaque to the hub:
 * M6's bridge owns their shape, and the hub only relays them. The index
 * signature keeps a caller's extra fields type-checked as unknowns rather than
 * silently dropped.
 */
export interface PassthroughPayload {
  kind: 'message' | 'status';
  [key: string]: unknown;
}

export type EventPayload =
  | StreamPayload
  | AgentPayload
  | ContextUsagePayload
  | SettledPayload
  | LeafPayload
  | ToolPayload
  | PassthroughPayload;

/** The single agent↔hub event, carrying a normalized payload. */
export interface EventMessage {
  protocolVersion: number;
  type: 'event';
  payload: EventPayload;
}

export interface RegisterMessage {
  protocolVersion: number;
  type: 'register';
  sessionId: string;
  sessionFile?: string;
  cwd?: string;
  name?: string;
  model?: string;
  thinkingLevel?: string;
  mode?: string;
  pid?: number;
  /** The hub session id this register replaces, after a `/new`/`/fork`. */
  replaces?: string;
}

export interface HistoryMessage {
  protocolVersion: number;
  type: 'history';
  sessionId: string;
  entries: unknown[];
  truncated: boolean;
  /**
   * The request's cursor echoed verbatim as a routing token, present whenever
   * the request carried one (honoured or not). Absent when the request had no
   * cursor, including a `fetchHistory` frame. It is **not** a statement that
   * older entries were delivered — that is `older`.
   */
  cursor?: string;
  /**
   * Present and `true` **exactly** when the bridge honoured the cursor and
   * `entries` are a genuinely older page. Absent is the only other state and
   * means "newest-page baseline", which the app applies as a REPLACE. The two
   * fields are split because a routing token is present whether or not the
   * cursor was honoured, while `older` must be present only when it was.
   */
  older?: boolean;
  /** The cursor for the next older page; present iff older entries remain. */
  olderCursor?: string;
}

/** The `{provider, id, name}` projection of a pi model the app needs. */
export interface ModelSummary {
  provider: string;
  id: string;
  name: string;
}

/** One node of the `/tree` picker, flattened from pi's session tree. */
export interface TreeNodeSummary {
  id: string;
  parentId: string | null;
  role: 'user' | 'assistant';
  label?: string;
  text: string;
}

export interface SlashCommand {
  name: string;
  description?: string;
}

export interface CommandResultMessage {
  protocolVersion: number;
  type: 'command-result';
  id: string;
  ok: boolean;
  error?: string;
  /** Present only on a `listCommands` result; validated if present. */
  commands?: SlashCommand[];
  /** Present only on a `listModels` result; validated if present. */
  models?: ModelSummary[];
  /** Present only on a `listTree` result; validated if present. */
  tree?: TreeNodeSummary[];
  /** True when `tree` dropped older nodes; validated if present. */
  treeTruncated?: boolean;
  /**
   * Present only on a `listTree` result: the current leaf, or `null` when the
   * tree has none. Validated if present; absent means an older bridge.
   */
  leafId?: string | null;
  /**
   * Tri-state: absent = the bridge did not queue this (unknown / not-queued);
   * `true` = accepted and dispatched as a mid-turn `steer`; `false` = never sent.
   * The bridge only ever emits `true` or omits the key; `false` exists so a future
   * producer can state "not sent" explicitly.
   */
  queued?: boolean;
}

export interface SubscribeMessage {
  protocolVersion: number;
  type: 'subscribe';
  sessionId: string;
}

export interface UnsubscribeMessage {
  protocolVersion: number;
  type: 'unsubscribe';
  sessionId: string;
}

export interface HistoryRequestMessage {
  protocolVersion: number;
  type: 'history-request';
  sessionId: string;
  sinceSeq?: number;
  /**
   * An opaque bridge-minted cursor naming the oldest entry already delivered;
   * absent asks for the newest page. Echoed verbatim on the answering
   * `history`/`snapshot` as a routing token (see `HistoryMessage.cursor`).
   */
  cursor?: string;
}

export interface CommandMessage {
  protocolVersion: number;
  type: 'command';
  id: string;
  sessionId: string;
  name: string;
  args?: unknown;
}

/**
 * A viewer asks the hub to spawn a headless pi session. Answered directly to
 * the issuing connection with a `command-result`; never forwarded to an agent.
 */
export interface StartSessionMessage {
  protocolVersion: number;
  type: 'start-session';
  id: string;
  /** Project directory to run the child pi in; absent means a temp dir. */
  cwd?: string;
  /** The user's trust decision for `cwd`; absent means "no new decision". */
  trust?: boolean;
}

/**
 * A viewer asks the hub to list the directories under the PC user's home.
 * Answered directly with a `dir-listing`; never forwarded to an agent. `path`
 * is absent for the browsing root.
 */
export interface ListDirsMessage {
  protocolVersion: number;
  type: 'list-dirs';
  id: string;
  path?: string;
}

/**
 * The hub's answer to a `list-dirs`: the sub-directories of `path`, the
 * browsing root, and the trust state pi would see for `path`.
 */
export interface DirListingMessage {
  protocolVersion: number;
  type: 'dir-listing';
  id: string;
  path: string;
  root: string;
  trust: boolean | null;
  trustRequired: boolean;
  entries: string[];
  truncated: boolean;
}

/**
 * A viewer asks the hub to kill an app-started session. Answered directly to
 * the issuing connection; never forwarded to an agent.
 */
export interface KillSessionMessage {
  protocolVersion: number;
  type: 'kill-session';
  id: string;
  sessionId: string;
}

/**
 * The hub's hub→viewer notice that a session settled. `label` is the session's
 * current viewer-safe label; `text`/`truncated` are the bridge's snippet.
 */
export interface AgentSettledMessage {
  protocolVersion: number;
  type: 'agent-settled';
  sessionId: string;
  label: string;
  text: string;
  truncated: boolean;
}

export interface PairedMessage {
  protocolVersion: number;
  type: 'paired';
  token: string;
}

/**
 * One registered session, summarised for a phone's session list. `label` is
 * the bridge's explicit `name` when pi has one, else the last user prompt,
 * else a viewer-safe basename of `sessionFile`/`cwd`, else the `sessionId`.
 * Deliberately narrower than the register record: `pid`/`cwd`/`model`/
 * `sessionFile` never travel as fields, and the hub invents no state —
 * `agentState` is the same value a `snapshot` reports. `lastSeq` is absent on
 * purpose: it changes on every stream delta, so a list carrying it would be
 * stale or force a push per token; a viewer that needs a watermark asks for a
 * `snapshot`.
 */
export interface SessionSummary {
  sessionId: string;
  label: string;
  agentState: AgentState;
  /** Validated if present; an absent field means `'pc'` (mixed-version skew). */
  origin?: SessionOrigin;
  /** The hub session id this one replaces, set only on `/new`/`/fork` successors. */
  replacesSessionId?: string;
}

export interface SessionsMessage {
  protocolVersion: number;
  type: 'sessions';
  sessions: SessionSummary[];
  /**
   * The hub's capabilities, absent on a pre-capabilities hub (which a viewer
   * must treat as the empty set). Validated-if-present, like `SessionSummary.origin`.
   */
  capabilities?: string[];
}

export interface SnapshotMessage {
  protocolVersion: number;
  type: 'snapshot';
  sessionId: string;
  lastSeq: number;
  agentState: AgentState;
  entries: unknown[];
  truncated: boolean;
  /**
   * The request's cursor echoed verbatim as a routing token, present whenever
   * the request carried one (honoured or not). Absent when the request had no
   * cursor. It is **not** a statement that older entries were delivered — that
   * is `older`.
   */
  cursor?: string;
  /**
   * Present and `true` **exactly** when the bridge honoured the cursor and
   * `entries` are a genuinely older page. Absent is the only other state and
   * means "newest-page baseline", which the app applies as a REPLACE.
   */
  older?: boolean;
  /** The cursor for the next older page; present iff older entries remain. */
  olderCursor?: string;
}

export interface SessionGoneMessage {
  protocolVersion: number;
  type: 'session-gone';
  sessionId: string;
}

export interface ResyncRequiredMessage {
  protocolVersion: number;
  type: 'resync-required';
  sessionId: string;
  reason: string;
}

/** The hub capabilities this protocol version advertises on the `sessions`
 * frame. Canonical; a viewer gates each capability's feature on its presence
 * (folder listing, folder-chosen starts, session control, image attachments). */
export const HUB_CAPABILITIES = ['list-dirs', 'project-session', 'session-control', 'attachments'] as const;
export type HubCapability = (typeof HUB_CAPABILITIES)[number];

/**
 * What each listener accepts besides `hello`; the listener *is* the role.
 *
 * These lists are canonical: the message unions and `decode`'s switch follow
 * them, never the reverse. A type added here must decode, and the fixture suite
 * fails until a minimal body and a golden fixture exist for it.
 */
export const AGENT_MESSAGE_TYPES = [
  'register',
  'event',
  'history',
  'command-result',
] as const;
export type AgentMessageType = (typeof AGENT_MESSAGE_TYPES)[number];

/** Canonical viewer→hub list; see [AGENT_MESSAGE_TYPES]. */
export const VIEWER_MESSAGE_TYPES = [
  'subscribe',
  'unsubscribe',
  'history-request',
  'command',
  'start-session',
  'kill-session',
  'list-dirs',
] as const;
export type ViewerMessageType = (typeof VIEWER_MESSAGE_TYPES)[number];

/**
 * The message types the hub sends to a viewer. Exported as a runtime list so
 * the fixture completeness assertion can prove every defined type has a
 * golden fixture (see `fixtures.test.ts`). Canonical; see
 * [AGENT_MESSAGE_TYPES].
 */
export const HUB_TO_VIEWER_MESSAGE_TYPES = [
  'paired',
  'sessions',
  'event',
  'snapshot',
  'command-result',
  'resync-required',
  'session-gone',
  'agent-settled',
  'dir-listing',
] as const;
export type HubToViewerMessageType = (typeof HUB_TO_VIEWER_MESSAGE_TYPES)[number];

/**
 * Every message type the protocol defines, in one list. A type added to any of
 * the per-direction lists above appears here automatically, and the fixture
 * suite fails until a valid fixture for it exists.
 */
export const ALL_MESSAGE_TYPES = [
  'hello',
  ...AGENT_MESSAGE_TYPES,
  ...VIEWER_MESSAGE_TYPES,
  ...HUB_TO_VIEWER_MESSAGE_TYPES,
] as const;
export type MessageType = (typeof ALL_MESSAGE_TYPES)[number];

export type AgentToHubMessage =
  | HelloMessage
  | RegisterMessage
  | EventMessage
  | HistoryMessage
  | CommandResultMessage;

export type ViewerToHubMessage =
  | HelloMessage
  | SubscribeMessage
  | UnsubscribeMessage
  | HistoryRequestMessage
  | CommandMessage
  | StartSessionMessage
  | KillSessionMessage
  | ListDirsMessage;

export type HubToViewerMessage =
  | PairedMessage
  | SessionsMessage
  | EventMessage
  | SnapshotMessage
  | CommandResultMessage
  | ResyncRequiredMessage
  | SessionGoneMessage
  | AgentSettledMessage
  | DirListingMessage;

/** Every message type `decode` understands. */
export type Message =
  | HelloMessage
  | RegisterMessage
  | EventMessage
  | HistoryMessage
  | CommandResultMessage
  | SubscribeMessage
  | UnsubscribeMessage
  | HistoryRequestMessage
  | CommandMessage
  | StartSessionMessage
  | KillSessionMessage
  | PairedMessage
  | SessionsMessage
  | SnapshotMessage
  | ResyncRequiredMessage
  | SessionGoneMessage
  | AgentSettledMessage
  | ListDirsMessage
  | DirListingMessage;

/** True when `type` is a message the agent listener accepts. */
export function isAgentMessageType(type: unknown): type is AgentMessageType {
  return typeof type === 'string' && (AGENT_MESSAGE_TYPES as readonly string[]).includes(type);
}

/** True when `type` is a message the viewer listener accepts. */
export function isViewerMessageType(type: unknown): type is ViewerMessageType {
  return (
    typeof type === 'string' && (VIEWER_MESSAGE_TYPES as readonly string[]).includes(type)
  );
}

/** The shared runtime guard for a non-empty string field. */
export function asString(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

/** The shared runtime guard for a plain JSON object field. */
export function asObject(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

/** True when `value` is a JS safe integer. */
function isSafeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value);
}

/** True when `value` is a positive safe integer (`stream.seq`, `sinceSeq`). */
function isPositiveSeq(value: unknown): value is number {
  return isSafeInteger(value) && value >= 1;
}

/** True when `value` is a non-negative safe integer (`snapshot.lastSeq`). */
function isNonNegativeSeq(value: unknown): value is number {
  return isSafeInteger(value) && value >= 0;
}

/** True when an optional field is absent or a string; a present `null` rejects. */
function isOptionalString(value: unknown): boolean {
  return value === undefined || typeof value === 'string';
}

/** True when `value` is a `{provider, id, name}` triple of non-empty strings. */
function isModelSummary(value: unknown): boolean {
  const model = asObject(value);
  return model !== null && asString(model.provider) !== null &&
    asString(model.id) !== null && asString(model.name) !== null;
}

/** True when `value` is a `{id, parentId, role, label?, text}` tree node. */
function isTreeNodeSummary(value: unknown): boolean {
  const node = asObject(value);
  return node !== null && asString(node.id) !== null &&
    (node.parentId === null || asString(node.parentId) !== null) &&
    (node.role === 'user' || node.role === 'assistant') &&
    isOptionalString(node.label) && typeof node.text === 'string';
}

/** Machine-readable failure reasons, stable enough for M5 to map and M7 to port. */
export type DecodeErrorCode =
  | 'malformed-json'
  | 'not-an-object'
  | 'bad-version'
  | 'unknown-type'
  | 'bad-credential'
  | 'bad-payload'
  | 'bad-seq'
  | 'bad-text'
  | 'bad-state'
  | 'bad-field';

export type DecodeResult =
  | { ok: true; value: Message }
  | { ok: false; code: DecodeErrorCode; error: string };

function fail(code: DecodeErrorCode, error: string): DecodeResult {
  return { ok: false, code, error };
}

/** Encodes exactly one JSON object per call. Trusts its typed input. */
export function encode(message: Message): string {
  return JSON.stringify(message);
}

/** Decodes one JSON object, reporting malformed input as a result, never a throw. */
export function decode(text: string): DecodeResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return fail('malformed-json', 'malformed JSON');
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return fail('not-an-object', 'message must be a JSON object');
  }
  const message = parsed as Record<string, unknown>;
  if (message.protocolVersion !== PROTOCOL_VERSION) {
    return fail(
      'bad-version',
      `unsupported protocolVersion: ${String(message.protocolVersion)}`,
    );
  }
  switch (message.type) {
    case 'hello': {
      const hasTicket = message.ticket !== undefined;
      const hasToken = message.token !== undefined;
      if (hasTicket === hasToken) {
        return fail('bad-credential', 'hello must carry exactly one of ticket or token');
      }
      const credential = hasTicket ? message.ticket : message.token;
      if (typeof credential !== 'string' || credential.length === 0) {
        return fail('bad-credential', 'hello credential must be a non-empty string');
      }
      return { ok: true, value: parsed as HelloMessage };
    }
    case 'event': {
      const payload = message.payload;
      if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) {
        return fail('bad-payload', 'event payload must be a JSON object');
      }
      const body = payload as Record<string, unknown>;
      const kind = body.kind;
      if (kind === 'stream') {
        const seq = body.seq;
        if (typeof seq !== 'number' || !Number.isSafeInteger(seq) || seq < 1) {
          return fail('bad-seq', 'stream seq must be a positive safe integer');
        }
        if (body.text !== undefined && typeof body.text !== 'string') {
          return fail('bad-text', 'stream text must be a string');
        }
        if (
          body.phase !== undefined &&
          !(STREAM_PHASES as readonly unknown[]).includes(body.phase)
        ) {
          return fail('bad-payload', `stream phase must be one of ${STREAM_PHASES.join(', ')}`);
        }
        if (body.text === undefined && body.phase === undefined) {
          return fail('bad-text', 'stream frame must carry text and/or a phase');
        }
        return { ok: true, value: parsed as EventMessage };
      }
      if (kind === 'agent') {
        if (!(AGENT_STATES as readonly unknown[]).includes(body.state)) {
          return fail('bad-state', 'agent state must be idle, running or settled');
        }
        return { ok: true, value: parsed as EventMessage };
      }
      if (kind === 'settled') {
        if (typeof body.text !== 'string') {
          return fail('bad-text', 'settled text must be a string');
        }
        if (typeof body.truncated !== 'boolean') {
          return fail('bad-field', 'settled truncated must be a boolean');
        }
        return { ok: true, value: parsed as EventMessage };
      }
      if (kind === 'leaf') {
        if (body.leafId !== null && asString(body.leafId) === null) {
          return fail('bad-field', 'leaf leafId must be a string or null');
        }
        return { ok: true, value: parsed as EventMessage };
      }
      // `message`/`status` are M6-owned shapes the hub only relays, so their
      // fields are accepted as-is once `kind` is recognized. `tool` is
      // validated on its identity fields only (`toolCallId`/`name`/`status`);
      // its optional `view` is carried through unvalidated so a `view`-absent
      // or unknown-`view.type` frame still decodes and falls back in the app.
      // `usage` is the same deal except for its `thinkingLevel`: the numbers
      // stay opaque, but the level is validated because the app reads it
      // directly. Note this is contract-pinning, not runtime defence — the hub
      // never calls `decode` on an event (it validates `hello` only), so the
      // app and the shared fixtures are the consumers this branch keeps honest.
      if (kind === 'tool') {
        if (asString(body.toolCallId) === null || asString(body.name) === null) {
          return fail('bad-field', 'tool requires toolCallId and name strings');
        }
        if (!(TOOL_STATUSES as readonly unknown[]).includes(body.status)) {
          return fail('bad-field', `tool status must be one of ${TOOL_STATUSES.join(', ')}`);
        }
        return { ok: true, value: parsed as EventMessage };
      }
      if (kind === 'message' || kind === 'status') {
        return { ok: true, value: parsed as EventMessage };
      }
      if (kind === 'usage') {
        if (!isOptionalString(body.thinkingLevel)) {
          return fail('bad-field', 'usage thinkingLevel must be a string');
        }
        if (body.model !== undefined && !isModelSummary(body.model)) {
          return fail('bad-field', 'usage model must carry provider, id and name strings');
        }
        return { ok: true, value: parsed as EventMessage };
      }
      return fail('bad-payload', `unknown event payload kind: ${String(kind)}`);
    }
    case 'register': {
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'register sessionId must be a non-empty string');
      }
      for (const field of [
        'sessionFile',
        'cwd',
        'name',
        'model',
        'thinkingLevel',
        'mode',
        'replaces',
      ]) {
        if (!isOptionalString(message[field])) {
          return fail('bad-field', `register ${field} must be a string`);
        }
      }
      if (message.pid !== undefined && !isSafeInteger(message.pid)) {
        return fail('bad-field', 'register pid must be a safe integer');
      }
      return { ok: true, value: parsed as RegisterMessage };
    }
    case 'history': {
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'history sessionId must be a non-empty string');
      }
      if (!Array.isArray(message.entries)) {
        return fail('bad-field', 'history entries must be an array');
      }
      if (typeof message.truncated !== 'boolean') {
        return fail('bad-field', 'history truncated must be a boolean');
      }
      if (!isOptionalString(message.cursor)) {
        return fail('bad-field', 'history cursor must be a string');
      }
      if (message.older !== undefined && typeof message.older !== 'boolean') {
        return fail('bad-field', 'history older must be a boolean');
      }
      if (!isOptionalString(message.olderCursor)) {
        return fail('bad-field', 'history olderCursor must be a string');
      }
      return { ok: true, value: parsed as HistoryMessage };
    }
    case 'command-result': {
      if (asString(message.id) === null) {
        return fail('bad-field', 'command-result id must be a non-empty string');
      }
      if (typeof message.ok !== 'boolean') {
        return fail('bad-field', 'command-result ok must be a boolean');
      }
      if (!isOptionalString(message.error)) {
        return fail('bad-field', 'command-result error must be a string');
      }
      if (message.commands !== undefined) {
        if (!Array.isArray(message.commands)) {
          return fail('bad-field', 'command-result commands must be an array');
        }
        for (const entry of message.commands) {
          if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
            return fail('bad-field', 'command-result commands entries must be JSON objects');
          }
          const command = entry as Record<string, unknown>;
          if (asString(command.name) === null) {
            return fail('bad-field', 'command-result command name must be a non-empty string');
          }
          if (!isOptionalString(command.description)) {
            return fail('bad-field', 'command-result command description must be a string');
          }
        }
      }
      if (message.models !== undefined) {
        if (!Array.isArray(message.models)) {
          return fail('bad-field', 'command-result models must be an array');
        }
        for (const entry of message.models) {
          if (!isModelSummary(entry)) {
            return fail('bad-field', 'command-result model must carry provider, id and name strings');
          }
        }
      }
      if (message.queued !== undefined && typeof message.queued !== 'boolean') {
        return fail('bad-field', 'command-result queued must be a boolean');
      }
      if (message.tree !== undefined) {
        if (!Array.isArray(message.tree)) {
          return fail('bad-field', 'command-result tree must be an array');
        }
        for (const entry of message.tree) {
          if (!isTreeNodeSummary(entry)) {
            return fail(
              'bad-field',
              'command-result tree nodes must carry id, parentId, role and text',
            );
          }
        }
      }
      if (
        message.leafId !== undefined &&
        message.leafId !== null &&
        asString(message.leafId) === null
      ) {
        return fail('bad-field', 'command-result leafId must be a string or null');
      }
      if (message.treeTruncated !== undefined && typeof message.treeTruncated !== 'boolean') {
        return fail('bad-field', 'command-result treeTruncated must be a boolean');
      }
      return { ok: true, value: parsed as CommandResultMessage };
    }
    case 'subscribe': {
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'subscribe sessionId must be a non-empty string');
      }
      return { ok: true, value: parsed as SubscribeMessage };
    }
    case 'unsubscribe': {
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'unsubscribe sessionId must be a non-empty string');
      }
      return { ok: true, value: parsed as UnsubscribeMessage };
    }
    case 'history-request': {
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'history-request sessionId must be a non-empty string');
      }
      if (message.sinceSeq !== undefined && !isPositiveSeq(message.sinceSeq)) {
        return fail('bad-seq', 'history-request sinceSeq must be a positive safe integer');
      }
      if (!isOptionalString(message.cursor)) {
        return fail('bad-field', 'history-request cursor must be a string');
      }
      return { ok: true, value: parsed as HistoryRequestMessage };
    }
    case 'command': {
      if (
        asString(message.id) === null ||
        asString(message.sessionId) === null ||
        asString(message.name) === null
      ) {
        return fail('bad-field', 'command requires id, sessionId and name strings');
      }
      return { ok: true, value: parsed as CommandMessage };
    }
    case 'start-session': {
      if (asString(message.id) === null) {
        return fail('bad-field', 'start-session id must be a non-empty string');
      }
      if (message.cwd !== undefined && asString(message.cwd) === null) {
        return fail('bad-field', 'start-session cwd must be a non-empty string');
      }
      if (message.trust !== undefined && typeof message.trust !== 'boolean') {
        return fail('bad-field', 'start-session trust must be a boolean');
      }
      return { ok: true, value: parsed as StartSessionMessage };
    }
    case 'list-dirs': {
      if (asString(message.id) === null) {
        return fail('bad-field', 'list-dirs id must be a non-empty string');
      }
      if (message.path !== undefined && asString(message.path) === null) {
        return fail('bad-field', 'list-dirs path must be a non-empty string');
      }
      return { ok: true, value: parsed as ListDirsMessage };
    }
    case 'dir-listing': {
      if (
        asString(message.id) === null ||
        asString(message.path) === null ||
        asString(message.root) === null
      ) {
        return fail('bad-field', 'dir-listing requires id, path and root strings');
      }
      if (message.trust !== null && typeof message.trust !== 'boolean') {
        return fail('bad-field', 'dir-listing trust must be null or a boolean');
      }
      if (typeof message.trustRequired !== 'boolean') {
        return fail('bad-field', 'dir-listing trustRequired must be a boolean');
      }
      if (
        !Array.isArray(message.entries) ||
        message.entries.some((entry) => asString(entry) === null)
      ) {
        return fail('bad-field', 'dir-listing entries must be non-empty strings');
      }
      if (typeof message.truncated !== 'boolean') {
        return fail('bad-field', 'dir-listing truncated must be a boolean');
      }
      return { ok: true, value: parsed as DirListingMessage };
    }
    case 'kill-session': {
      if (asString(message.id) === null) {
        return fail('bad-field', 'kill-session id must be a non-empty string');
      }
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'kill-session sessionId must be a non-empty string');
      }
      return { ok: true, value: parsed as KillSessionMessage };
    }
    case 'paired': {
      if (asString(message.token) === null) {
        return fail('bad-field', 'paired token must be a non-empty string');
      }
      return { ok: true, value: parsed as PairedMessage };
    }
    case 'sessions': {
      if (!Array.isArray(message.sessions)) {
        return fail('bad-field', 'sessions must be an array');
      }
      for (const entry of message.sessions) {
        if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
          return fail('bad-field', 'sessions entries must be JSON objects');
        }
        const summary = entry as Record<string, unknown>;
        if (asString(summary.sessionId) === null) {
          return fail('bad-field', 'sessions sessionId must be a non-empty string');
        }
        if (asString(summary.label) === null) {
          return fail('bad-field', 'sessions label must be a non-empty string');
        }
        if (!(AGENT_STATES as readonly unknown[]).includes(summary.agentState)) {
          return fail('bad-state', 'sessions agentState must be idle, running or settled');
        }
        if (
          summary.origin !== undefined &&
          !(SESSION_ORIGINS as readonly unknown[]).includes(summary.origin)
        ) {
          return fail('bad-field', 'sessions origin must be app or pc');
        }
        if (!isOptionalString(summary.replacesSessionId)) {
          return fail('bad-field', 'sessions replacesSessionId must be a string');
        }
      }
      if (
        message.capabilities !== undefined &&
        (!Array.isArray(message.capabilities) ||
          message.capabilities.some((capability) => asString(capability) === null))
      ) {
        return fail('bad-field', 'sessions capabilities must be non-empty strings');
      }
      return { ok: true, value: parsed as SessionsMessage };
    }
    case 'snapshot': {
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'snapshot sessionId must be a non-empty string');
      }
      if (!isNonNegativeSeq(message.lastSeq)) {
        return fail('bad-field', 'snapshot lastSeq must be a non-negative safe integer');
      }
      if (!(AGENT_STATES as readonly unknown[]).includes(message.agentState)) {
        return fail('bad-state', 'snapshot agentState must be idle, running or settled');
      }
      if (!Array.isArray(message.entries)) {
        return fail('bad-field', 'snapshot entries must be an array');
      }
      if (typeof message.truncated !== 'boolean') {
        return fail('bad-field', 'snapshot truncated must be a boolean');
      }
      if (!isOptionalString(message.cursor)) {
        return fail('bad-field', 'snapshot cursor must be a string');
      }
      if (message.older !== undefined && typeof message.older !== 'boolean') {
        return fail('bad-field', 'snapshot older must be a boolean');
      }
      if (!isOptionalString(message.olderCursor)) {
        return fail('bad-field', 'snapshot olderCursor must be a string');
      }
      return { ok: true, value: parsed as SnapshotMessage };
    }
    case 'resync-required': {
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'resync-required sessionId must be a non-empty string');
      }
      if (asString(message.reason) === null) {
        return fail('bad-field', 'resync-required reason must be a non-empty string');
      }
      return { ok: true, value: parsed as ResyncRequiredMessage };
    }
    case 'session-gone': {
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'session-gone sessionId must be a non-empty string');
      }
      return { ok: true, value: parsed as SessionGoneMessage };
    }
    case 'agent-settled': {
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'agent-settled sessionId must be a non-empty string');
      }
      if (asString(message.label) === null) {
        return fail('bad-field', 'agent-settled label must be a non-empty string');
      }
      if (typeof message.text !== 'string') {
        return fail('bad-field', 'agent-settled text must be a string');
      }
      if (typeof message.truncated !== 'boolean') {
        return fail('bad-field', 'agent-settled truncated must be a boolean');
      }
      return { ok: true, value: parsed as AgentSettledMessage };
    }
    default:
      return fail('unknown-type', `unknown message type: ${String(message.type)}`);
  }
}
