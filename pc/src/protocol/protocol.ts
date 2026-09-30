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
 * The wire protocol, in one place.
 *
 * A Dart port works from this block alone.
 *
 * ## Close codes (WebSocket application range 4000-4999)
 * - `4002` capability/protocol violation: a message a listener does not permit,
 *   a bad `protocolVersion`, malformed JSON, a missing required field, or a
 *   permitted type with no dispatch branch (the hub fails closed).
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

/** A token-stream delta, ordered by `seq`. Carried inside an `event`. */
export interface StreamPayload {
  kind: 'stream';
  seq: number;
  text: string;
}

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

/** What each listener accepts besides `hello`; the listener *is* the role. */
export const AGENT_MESSAGE_TYPES = [
  'register',
  'event',
  'history',
  'command-result',
] as const;
export type AgentMessageType = (typeof AGENT_MESSAGE_TYPES)[number];

export const VIEWER_MESSAGE_TYPES = [
  'subscribe',
  'unsubscribe',
  'history-request',
  'command',
] as const;
export type ViewerMessageType = (typeof VIEWER_MESSAGE_TYPES)[number];

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
  | EventMessage
  | SnapshotMessage
  | CommandResultMessage
  | ResyncRequiredMessage
  | SessionGoneMessage;

/** The two message types `decode` understands in full. */
export type Message = HelloMessage | EventMessage;

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
  | 'bad-state';

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
        if (typeof body.text !== 'string') {
          return fail('bad-text', 'stream text must be a string');
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
    default:
      return fail('unknown-type', `unknown message type: ${String(message.type)}`);
  }
}
