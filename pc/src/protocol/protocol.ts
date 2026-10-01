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
 * The bridge's history window. A `snapshot` answering a `history-request` is a
 * control *response* the viewer asked for, delivered unbudgeted, so its only
 * hard ceiling is the hub's 1 MiB frame cap. Deliberately larger than
 * `MAX_RELAY_BYTES`: that one sizes a single relayed message, this one sizes
 * depth, and sharing one number between the two jobs hid everything but the
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
 *
 * ## Envelope
 * Every message is one JSON object with `protocolVersion` and `type`.
 *
 * agent -> hub (loopback listener):
 * - `hello`  { ticket XOR token }
 * - `register` { sessionId, sessionFile?, cwd?, name?, model?, thinkingLevel?, mode?, pid? }
 * - `event`  { payload: stream | message | agent | tool | status }
 * - `history` { sessionId, entries: unknown[], truncated: boolean }
 * - `command-result` { id, ok, error? }
 *
 * viewer -> hub (LAN listener):
 * - `hello`  { ticket XOR token }
 * - `subscribe` / `unsubscribe` { sessionId }
 * - `history-request` { sessionId, sinceSeq? }
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
 * - `snapshot` { sessionId, lastSeq, agentState, entries: unknown[], truncated }
 *   — `lastSeq`/`agentState` are hub-tracked; `entries` are agent-supplied and
 *   may be truncated.
 * - `command-result` { id, ok, error? }
 * - `resync-required` { sessionId, reason }
 * - `session-gone` { sessionId }
 *
 * hub -> agent:
 * - `command` (forwarded verbatim, including `id`)
 * - `history-request` { sessionId, sinceSeq? }
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

/** The normalized payload kinds an `event` may carry. */
export const EVENT_PAYLOAD_KINDS = ['stream', 'message', 'agent', 'tool', 'status'] as const;
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

/** The agent's lifecycle transition. Carried inside an `event`. */
export interface AgentPayload {
  kind: 'agent';
  state: AgentState;
}

/**
 * The remaining normalized kinds (`message`, `tool`, `status`) are opaque to
 * the hub: M6's bridge owns their shape, and the hub only relays them. The
 * index signature keeps a caller's extra fields type-checked as unknowns
 * rather than silently dropped.
 */
export interface PassthroughPayload {
  kind: 'message' | 'tool' | 'status';
  [key: string]: unknown;
}

export type EventPayload = StreamPayload | AgentPayload | PassthroughPayload;

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
}

export interface HistoryMessage {
  protocolVersion: number;
  type: 'history';
  sessionId: string;
  entries: unknown[];
  truncated: boolean;
}

export interface CommandResultMessage {
  protocolVersion: number;
  type: 'command-result';
  id: string;
  ok: boolean;
  error?: string;
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
}

export interface CommandMessage {
  protocolVersion: number;
  type: 'command';
  id: string;
  sessionId: string;
  name: string;
  args?: unknown;
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
}

export interface SessionsMessage {
  protocolVersion: number;
  type: 'sessions';
  sessions: SessionSummary[];
}

export interface SnapshotMessage {
  protocolVersion: number;
  type: 'snapshot';
  sessionId: string;
  lastSeq: number;
  agentState: AgentState;
  entries: unknown[];
  truncated: boolean;
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
  | CommandMessage;

export type HubToViewerMessage =
  | PairedMessage
  | SessionsMessage
  | EventMessage
  | SnapshotMessage
  | CommandResultMessage
  | ResyncRequiredMessage
  | SessionGoneMessage;

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
  | PairedMessage
  | SessionsMessage
  | SnapshotMessage
  | ResyncRequiredMessage
  | SessionGoneMessage;

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
      // `message`/`tool`/`status` are M6-owned shapes the hub only relays, so
      // their fields are accepted as-is once `kind` is recognized.
      if (kind === 'message' || kind === 'tool' || kind === 'status') {
        return { ok: true, value: parsed as EventMessage };
      }
      return fail('bad-payload', `unknown event payload kind: ${String(kind)}`);
    }
    case 'register': {
      if (asString(message.sessionId) === null) {
        return fail('bad-field', 'register sessionId must be a non-empty string');
      }
      for (const field of ['sessionFile', 'cwd', 'name', 'model', 'thinkingLevel', 'mode']) {
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
    default:
      return fail('unknown-type', `unknown message type: ${String(message.type)}`);
  }
}
