/**
 * The hub: two listeners, listener-bound capabilities, relay and backpressure.
 *
 * One WebSocket server per role. The agent listener binds `127.0.0.1:0` (an
 * ephemeral loopback port, published in the discovery file). The viewer
 * listener binds `0.0.0.0:<port>` normally, or `127.0.0.1:<port>` under
 * `--no-lan`. Capabilities are enforced per listener: the agent port accepts
 * only agent-side messages, the viewer port only viewer-side ones. There is no
 * `role` field — the listener *is* the role.
 *
 * Authentication happens on `hello`, and only on `hello`. A wrong credential is
 * charged against a per-connection cap, and the connection is closed once the
 * cap is reached; any non-`hello` message before authentication is a protocol
 * violation and closes immediately. Closing is delayed briefly for the attempt
 * cap so a socket cannot be used as a fast token oracle.
 *
 * The hub is a registry + relay. It never interprets the normalized payload
 * beyond what resync requires (`lastSeq` and `agentState`); everything else is
 * forwarded. A registered agent's events go to that session's subscribers; a
 * viewer's command goes to the session's agent and the result comes back to the
 * viewer that issued it.
 *
 * `ws` is the one runtime dependency, added because Node ships a WebSocket
 * *client* but no server.
 */

import { once } from 'node:events';
import { basename } from 'node:path';

import { WebSocket, WebSocketServer } from 'ws';
import type { RawData } from 'ws';

import {
  EVENT_PAYLOAD_KINDS,
  MAX_RELAY_BYTES,
  PROTOCOL_VERSION,
  STREAM_PHASES,
  asObject,
  asString,
  decode,
  isAgentMessageType,
  isViewerMessageType,
} from '../protocol/protocol.ts';
import type {
  AgentSettledMessage,
  AgentState,
  SessionOrigin,
  SessionsMessage,
} from '../protocol/protocol.ts';
import { compareToken } from './auth.ts';
import { ByteBudget } from './backpressure.ts';
import type { TicketStore } from './pairing.ts';
import type { Spawner } from './spawner.ts';

/**
 * Application close codes (4000–4999). The full table and the message shapes
 * live in `protocol.ts`; this is the enforcement site.
 *
 * - `CLOSE_PROTOCOL` (4002): malformed JSON, a bad `protocolVersion`, a missing
 *   required field, an explicit session takeover displacing an agent, or a
 *   permitted type with no dispatch branch (dispatch fails closed).
 * - `CLOSE_CAPABILITY` (4003): a message this listener does not permit.
 * - `CLOSE_RATE_LIMITED` (4008): the failed-credential cap was reached. It is
 *   sent **after a short delay** so the socket cannot be used as a fast token
 *   oracle.
 */
export const CLOSE_PROTOCOL = 4002;
export const CLOSE_CAPABILITY = 4003;
export const CLOSE_RATE_LIMITED = 4008;

const DEFAULT_MAX_AUTH_ATTEMPTS = 3;
const DEFAULT_AUTH_CLOSE_DELAY_MS = 250;
/** Cap on a single inbound frame; `ws` defaults to 100 MB, far too generous. */
const DEFAULT_MAX_PAYLOAD = 1024 * 1024;

/** The bridge's command allowlist; anything else is refused here too. */
const COMMAND_ALLOWLIST = new Set([
  'prompt',
  'steer',
  'followup',
  'abort',
  'setModel',
  'setThinkingLevel',
  'compact',
  'fetchHistory',
  'setSessionName',
]);

export interface HubOptions {
  /** The persistent token viewers and agents authenticate with. */
  token: string;
  /** The one-outstanding-ticket authority used to pair a phone. */
  tickets: TicketStore;
  /** Viewer listener port; 0 selects an ephemeral port. */
  viewerPort: number;
  /** Viewer bind address. Defaults to `0.0.0.0`; `--no-lan` passes `127.0.0.1`. */
  viewerHost?: string;
  /** Failed credential attempts a connection gets before it is closed. */
  maxAuthAttempts?: number;
  /** Delay before closing a connection that exhausted its attempts. */
  authCloseDelayMs?: number;
  /** Per-viewer budget for relayed events, in bytes. */
  maxViewerBytes?: number;
  /** Maximum size of a single inbound frame, in bytes. Defaults to 1 MiB. */
  maxPayload?: number;
  /** The process supervisor for app-started sessions, when one is configured. */
  spawner?: Spawner;
}

export interface Hub {
  /** The real agent-listener port (ephemeral). */
  readonly agentPort: number;
  /** The real viewer-listener port. */
  readonly viewerPort: number;
  /** Closes both listeners and terminates every open socket. */
  close(): Promise<void>;
}

type Listener = 'agent' | 'viewer';

interface Connection {
  readonly listener: Listener;
  readonly socket: WebSocket;
  readonly budget: ByteBudget;
  authenticated: boolean;
  authAttempts: number;
  closing: boolean;
  /** Session ids this viewer has been told to resync; cleared per session. */
  readonly resyncAnnounced: Set<string>;
}

interface Session {
  readonly sessionId: string;
  /** Derived once at register time; re-derived on a re-register/takeover. */
  label: string;
  agent: Connection;
  lastSeq: number;
  agentState: AgentState;
  /** The register's reported pid, when present; used to derive `origin`. */
  pid?: number;
  /** Who started this session: `app` when the spawner owns its pid, else `pc`. */
  origin: SessionOrigin;
  readonly subscribers: Set<Connection>;
  readonly pendingHistory: Set<Connection>;
  /** `id` -> viewers awaiting its result, in issue order. */
  readonly pendingCommands: Map<string, Connection[]>;
}

interface State {
  readonly config: {
    token: string;
    tickets: TicketStore;
    maxAuthAttempts: number;
    authCloseDelayMs: number;
    maxViewerBytes: number;
    spawner?: Spawner;
  };
  readonly sessions: Map<string, Session>;
  /** Authenticated viewer connections; the broadcast audience for `sessions`. */
  readonly viewers: Set<Connection>;
}

async function listen(server: WebSocketServer): Promise<void> {
  // `WebSocketServer` starts listening on construction; await the first of
  // 'listening' or 'error' so a port clash rejects this promise instead of
  // crashing the process.
  const failure = new Promise<never>((_, reject) => {
    server.once('error', reject);
  });
  await Promise.race([once(server, 'listening').then(() => undefined), failure]);
}

function closeServer(server: WebSocketServer): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

function addressPort(server: WebSocketServer): number {
  const address = server.address();
  if (address === null || typeof address === 'string') {
    throw new Error('server has no TCP address');
  }
  return address.port;
}

function send(connection: Connection, message: unknown): void {
  if (connection.socket.readyState !== WebSocket.OPEN) return;
  connection.socket.send(JSON.stringify(message));
}

/**
 * A viewer-safe label: the session's `name` verbatim; for an app-started
 * session with no name, the placeholder `New session` (its temp cwd/session
 * path is meaningless to a viewer); otherwise the basename of its
 * `sessionFile` or `cwd`; otherwise the opaque `sessionId`. A full filesystem
 * path is never exposed as a label.
 */
function registerLabel(
  message: Record<string, unknown>,
  sessionId: string,
  origin: SessionOrigin,
): string {
  const name = asString(message.name);
  if (name !== null) return name;
  if (origin === 'app') return 'New session';
  for (const candidate of [message.sessionFile, message.cwd]) {
    const value = asString(candidate);
    if (value === null) continue;
    const base = basename(value);
    if (base.length > 0 && base !== '/') return base;
  }
  return sessionId;
}

/**
 * The registry as a summary list: one entry per registered session, in
 * `sessionId` order. `label` is viewer-safe (a basename, never a full path);
 * the register record's `pid`, `cwd`, `model` and `sessionFile` never travel
 * to a viewer as fields. `lastSeq` is deliberately absent: it moves on every
 * stream delta, so a list carrying it would either be stale or force a push
 * per token; a viewer that needs a watermark asks for a `snapshot`.
 */
function sessionsMessage(state: State): SessionsMessage {
  return {
    protocolVersion: PROTOCOL_VERSION,
    type: 'sessions',
    sessions: [...state.sessions.values()]
      .sort((a, b) => (a.sessionId < b.sessionId ? -1 : a.sessionId > b.sessionId ? 1 : 0))
      .map((session) => ({
        sessionId: session.sessionId,
        label: session.label,
        agentState: session.agentState,
        origin: session.origin,
      })),
  };
}

/** Pushes the current list to one connection. Viewer-only by construction. */
function pushSessions(state: State, connection: Connection): void {
  if (connection.listener !== 'viewer') return;
  sendToViewer(connection, sessionsMessage(state), null);
}

/** Pushes the current list to every authenticated viewer. */
function broadcastSessions(state: State): void {
  for (const viewer of state.viewers) {
    if (viewer.authenticated) pushSessions(state, viewer);
  }
}

/**
 * Tells every authenticated viewer that a session settled. A notification is
 * viewer-scoped, not subscriber-scoped: the phone must be able to notify for a
 * session it is not viewing. Best-effort (`sessionId` null) deliberately: a
 * throttled viewer cannot be allowed to trigger a resync storm for a 200-char
 * snippet.
 */
function broadcastAgentSettled(
  state: State,
  session: Session,
  text: string,
  truncated: boolean,
): void {
  const message: AgentSettledMessage = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'agent-settled',
    sessionId: session.sessionId,
    label: session.label,
    text,
    truncated,
  };
  for (const viewer of state.viewers) {
    if (viewer.authenticated) sendToViewer(viewer, message, null);
  }
}

/**
 * Control messages are tiny and deliberately unbudgeted: a dropped
 * `resync-required` would strand a throttled viewer forever. The cap exists to
 * bound unsolicited bulk, which all goes through `sendToViewer`.
 */
function announceResync(viewer: Connection, sessionId: string): void {
  if (viewer.resyncAnnounced.has(sessionId)) return;
  viewer.resyncAnnounced.add(sessionId);
  send(viewer, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'resync-required',
    sessionId,
    reason: 'backpressure',
  });
}

/**
 * Sends one viewer-bound message under its byte budget. A message that does
 * not fit is dropped whole; when it carried session data (`sessionId` non-null)
 * the viewer is told once to resync. This is the budgeted path for unsolicited
 * traffic (relayed events, `sessions`, `session-gone`, `command-result`,
 * `paired`); it cannot be used to push bytes at a viewer that did not ask. A
 * response to an explicit request (`snapshot`) and a recovery control
 * (`resync-required`) are not unsolicited: they are sent via `send()` instead
 * and are never dropped, so a throttled viewer is not stranded.
 */
function sendToViewer(
  viewer: Connection,
  message: unknown,
  sessionId: string | null,
): void {
  if (viewer.socket.readyState !== WebSocket.OPEN) return;
  const text = JSON.stringify(message);
  const bytes = Buffer.byteLength(text);
  if (viewer.budget.admit(bytes)) {
    viewer.socket.send(text, () => viewer.budget.drain(bytes));
    return;
  }
  if (sessionId !== null) announceResync(viewer, sessionId);
}

function closeWith(connection: Connection, code: number, reason?: string): void {
  connection.closing = true;
  connection.socket.close(code, reason);
}

function failAuth(connection: Connection, config: State['config']): void {
  connection.authAttempts += 1;
  if (connection.authAttempts < config.maxAuthAttempts) return;
  connection.closing = true;
  const timer = setTimeout(() => {
    connection.socket.close(CLOSE_RATE_LIMITED);
  }, config.authCloseDelayMs);
  timer.unref();
}

function authenticate(connection: Connection, text: string, state: State): void {
  const result = decode(text);
  if (!result.ok || result.value.type !== 'hello') {
    failAuth(connection, state.config);
    return;
  }
  const hello = result.value;
  if ('ticket' in hello) {
    const redeemed = state.config.tickets.redeem(hello.ticket);
    if (!redeemed.ok) {
      failAuth(connection, state.config);
      return;
    }
    connection.authenticated = true;
    sendToViewer(connection, {
      protocolVersion: PROTOCOL_VERSION,
      type: 'paired',
      token: state.config.token,
    }, null);
    pushSessions(state, connection);
    return;
  }
  if (!compareToken(hello.token, state.config.token)) {
    failAuth(connection, state.config);
    return;
  }
  connection.authenticated = true;
  pushSessions(state, connection);
}

function handleMessage(state: State, connection: Connection, data: RawData): void {
  if (connection.closing) return;
  const text = typeof data === 'string' ? data : data.toString('utf8');
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const message = parsed as Record<string, unknown>;
  const type = message.type;
  if (!connection.authenticated) {
    // Only `hello` is ever processed before authentication. Any other message
    // while unauthenticated is a protocol violation: silently ignoring it would
    // leave a stale-token bridge "connected" forever, streaming into the void.
    if (type === 'hello') {
      authenticate(connection, text, state);
    } else {
      closeWith(connection, CLOSE_PROTOCOL);
    }
    return;
  }
  const permitted =
    connection.listener === 'agent' ? isAgentMessageType(type) : isViewerMessageType(type);
  if (!permitted) {
    closeWith(connection, CLOSE_CAPABILITY);
    return;
  }
  dispatch(state, connection, message);
}

/** The session this agent connection currently owns, if any. */
function ownedSession(state: State, connection: Connection): Session | null {
  for (const session of state.sessions.values()) {
    if (session.agent === connection) return session;
  }
  return null;
}

function retireSession(state: State, sessionId: string): void {
  const session = state.sessions.get(sessionId);
  if (session === undefined) return;
  state.sessions.delete(sessionId);
  for (const subscriber of session.subscribers) {
    sendToViewer(subscriber, {
      protocolVersion: PROTOCOL_VERSION,
      type: 'session-gone',
      sessionId,
    }, sessionId);
  }
}

function handleRegister(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const sessionId = asString(message.sessionId);
  if (sessionId === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const pid = typeof message.pid === 'number' ? message.pid : undefined;
  const spawner = state.config.spawner;
  const owned = pid !== undefined && spawner !== undefined && spawner.owns(pid);
  const origin: SessionOrigin = owned ? 'app' : 'pc';
  if (owned && pid !== undefined) spawner!.confirm(pid);
  const label = registerLabel(message, sessionId, origin);
  // Switch/fork: one connection owns at most one session; registering a new id
  // retires the old one and tells its subscribers it is gone.
  const previous = ownedSession(state, connection);
  if (previous !== null && previous.sessionId !== sessionId) {
    retireSession(state, previous.sessionId);
  }
  const existing = state.sessions.get(sessionId);
  if (existing !== undefined) {
    // A takeover is explicit: the displaced agent is closed now, with a reason,
    // rather than being left to discover it on its next event (which would earn
    // a protocol close anyway, but incidentally).
    if (existing.agent !== connection) {
      closeWith(existing.agent, CLOSE_PROTOCOL, 'session taken over');
    }
    existing.agent = connection;
    existing.pid = pid;
    // Only a label or origin change is worth a broadcast: the bridge
    // re-registers on every reconnect, and non-bridge agents may re-register
    // unchanged too. An origin change matters because it flips whether the app
    // offers a kill affordance.
    if (existing.label !== label || existing.origin !== origin) {
      existing.label = label;
      existing.origin = origin;
      broadcastSessions(state);
    }
    return;
  }
  state.sessions.set(sessionId, {
    sessionId,
    label,
    agent: connection,
    lastSeq: 0,
    agentState: 'idle',
    pid,
    origin,
    subscribers: new Set(),
    pendingHistory: new Set(),
    pendingCommands: new Map(),
  });
  broadcastSessions(state);
}

function handleEvent(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const session = ownedSession(state, connection);
  if (session === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const payload = asObject(message.payload);
  if (payload === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const kind = payload.kind;
  if (kind === 'stream') {
    const seq = payload.seq;
    if (typeof seq !== 'number' || !Number.isSafeInteger(seq) || seq < 1) {
      closeWith(connection, CLOSE_PROTOCOL);
      return;
    }
    if (payload.text !== undefined && typeof payload.text !== 'string') {
      closeWith(connection, CLOSE_PROTOCOL);
      return;
    }
    if (
      payload.phase !== undefined &&
      !(STREAM_PHASES as readonly unknown[]).includes(payload.phase)
    ) {
      closeWith(connection, CLOSE_PROTOCOL);
      return;
    }
    if (payload.text === undefined && payload.phase === undefined) {
      closeWith(connection, CLOSE_PROTOCOL);
      return;
    }
    session.lastSeq = Math.max(session.lastSeq, seq);
  } else if (kind === 'agent') {
    if (payload.state !== 'idle' && payload.state !== 'running' && payload.state !== 'settled') {
      closeWith(connection, CLOSE_PROTOCOL);
      return;
    }
    // Broadcast on a transition only: a stream delta bumps `lastSeq` but does
    // not change the list a viewer reads, and pushing per token would be noise.
    if (payload.state !== session.agentState) {
      session.agentState = payload.state;
      broadcastSessions(state);
    }
  } else if (kind === 'settled') {
    if (typeof payload.text !== 'string' || typeof payload.truncated !== 'boolean') {
      closeWith(connection, CLOSE_PROTOCOL);
      return;
    }
    // A notification concern, not a transcript frame: broadcast to EVERY
    // authenticated viewer, then return so it is not also relayed to
    // subscribers (the fall-through would deliver every settle twice).
    broadcastAgentSettled(state, session, payload.text, payload.truncated);
    return;
  } else if (!(EVENT_PAYLOAD_KINDS as readonly unknown[]).includes(kind)) {
    // `message`/`tool`/`status` are relayed untouched; only a genuinely
    // unknown kind is a protocol violation.
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  for (const subscriber of session.subscribers) relayToViewer(subscriber, message, session.sessionId);
}

/**
 * Relays one event to one viewer under its byte budget. A message that does not
 * fit is dropped whole; the viewer is told once per session to resync, and its
 * next `history-request` rebuilds it from the hub's tracked `lastSeq`/`agentState`.
 */
function relayToViewer(viewer: Connection, message: unknown, sessionId: string): void {
  sendToViewer(viewer, message, sessionId);
}

function commandResult(id: string, ok: boolean, error: string): unknown {
  return { protocolVersion: PROTOCOL_VERSION, type: 'command-result', id, ok, error };
}

/** An `ok` result deliberately carries no `error` field. */
function commandOk(id: string): unknown {
  return { protocolVersion: PROTOCOL_VERSION, type: 'command-result', id, ok: true };
}

/**
 * A viewer asks the hub to spawn a headless pi session. Answered directly to
 * the issuing connection: the result is produced locally, not by an agent
 * round-trip, so there is no per-session pending map to key it into. Two
 * viewers using the same id each receive their own reply.
 */
function handleStartSession(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const id = asString(message.id);
  if (id === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const spawner = state.config.spawner;
  if (spawner === undefined) {
    sendToViewer(
      connection,
      commandResult(id, false, 'starting sessions is not available on this hub'),
      null,
    );
    return;
  }
  spawner.spawn().then(
    () => sendToViewer(connection, commandOk(id), null),
    (error: unknown) =>
      sendToViewer(
        connection,
        commandResult(id, false, String((error as Error)?.message ?? error)),
        null,
      ),
  );
}

/**
 * A viewer asks the hub to kill an app-started session. Only a session the
 * spawner still owns may be killed; a PC-started session is refused. Answered
 * directly to the issuing connection.
 */
function handleKillSession(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const id = asString(message.id);
  const sessionId = asString(message.sessionId);
  if (id === null || sessionId === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const session = state.sessions.get(sessionId);
  if (session === undefined) {
    sendToViewer(connection, commandResult(id, false, 'unknown session'), null);
    return;
  }
  const spawner = state.config.spawner;
  if (
    session.origin !== 'app' ||
    session.pid === undefined ||
    spawner === undefined ||
    !spawner.owns(session.pid)
  ) {
    sendToViewer(connection, commandResult(id, false, 'not an app session'), null);
    return;
  }
  // Reply before signalling: the app's pending kill completes on the result,
  // not on the session-gone the kill will eventually provoke.
  sendToViewer(connection, commandOk(id), null);
  spawner.kill(session.pid);
}

function handleCommand(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const id = asString(message.id);
  const sessionId = asString(message.sessionId);
  const name = asString(message.name);
  if (id === null || sessionId === null || name === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  if (!COMMAND_ALLOWLIST.has(name)) {
    sendToViewer(connection, commandResult(id, false, 'unknown command'), null);
    return;
  }
  const session = state.sessions.get(sessionId);
  if (session === undefined) {
    sendToViewer(connection, commandResult(id, false, 'unknown session'), null);
    return;
  }
  // Keyed by (session, id) with the issuing viewer queued: two viewers using
  // the same id no longer overwrite one another.
  const queue = session.pendingCommands.get(id);
  if (queue === undefined) session.pendingCommands.set(id, [connection]);
  else queue.push(connection);
  send(session.agent, message);
}

function handleCommandResult(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const id = asString(message.id);
  if (id === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  // Only the agent that owns the session may answer for it; another agent's
  // result is dropped rather than routed into this session's viewer.
  const session = ownedSession(state, connection);
  if (session === null) return;
  const queue = session.pendingCommands.get(id);
  if (queue === undefined || queue.length === 0) return;
  const viewer = queue.shift()!;
  if (queue.length === 0) session.pendingCommands.delete(id);
  sendToViewer(viewer, message, session.sessionId);
}

function handleSubscribe(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const sessionId = asString(message.sessionId);
  if (sessionId === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const session = state.sessions.get(sessionId);
  if (session === undefined) {
    sendToViewer(connection, {
      protocolVersion: PROTOCOL_VERSION,
      type: 'session-gone',
      sessionId,
    }, null);
    return;
  }
  session.subscribers.add(connection);
}

function handleUnsubscribe(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const sessionId = asString(message.sessionId);
  if (sessionId === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  state.sessions.get(sessionId)?.subscribers.delete(connection);
}

function handleHistory(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const sessionId = asString(message.sessionId);
  if (sessionId === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const session = state.sessions.get(sessionId);
  if (session === undefined || session.agent !== connection) return;
  const entries = Array.isArray(message.entries) ? message.entries : [];
  const truncated = message.truncated === true;
  for (const viewer of session.pendingHistory) {
    // A snapshot answering a `history-request` is a control *response*, not
    // bulk relay: the viewer asked for it, so it cannot be used to push
    // unsolicited bytes, and it must not be dropped. Budgeting it caused a
    // livelock — a snapshot larger than the viewer cap was dropped, the viewer
    // was told to resync, its next request produced the same oversized
    // snapshot, and so on. Like `resync-required`, deliver it unbudgeted.
    send(viewer, {
      protocolVersion: PROTOCOL_VERSION,
      type: 'snapshot',
      sessionId,
      lastSeq: session.lastSeq,
      agentState: session.agentState,
      entries,
      truncated,
    });
  }
  session.pendingHistory.clear();
}

/**
 * Concurrent requests for one session are coalesced: the first is forwarded to
 * the agent, later ones just join the reply list, so N viewers cannot stampede
 * one agent. The session's tracked `lastSeq`/`agentState` are authoritative.
 */
function handleHistoryRequest(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const sessionId = asString(message.sessionId);
  if (sessionId === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  // `sinceSeq` is viewer-supplied and forwarded, so it gets the same
  // positive-safe-integer validation as a `stream.seq`.
  const sinceSeq = message.sinceSeq;
  if (
    sinceSeq !== undefined &&
    (typeof sinceSeq !== 'number' || !Number.isSafeInteger(sinceSeq) || sinceSeq < 1)
  ) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const session = state.sessions.get(sessionId);
  if (session === undefined) {
    sendToViewer(connection, {
      protocolVersion: PROTOCOL_VERSION,
      type: 'session-gone',
      sessionId,
    }, null);
    return;
  }
  connection.resyncAnnounced.delete(sessionId);
  const firstRequest = session.pendingHistory.size === 0;
  session.pendingHistory.add(connection);
  if (!firstRequest) return;
  const forwarded: Record<string, unknown> = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId,
  };
  if (sinceSeq !== undefined) forwarded.sinceSeq = sinceSeq;
  send(session.agent, forwarded);
}

function dispatch(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  if (message.protocolVersion !== PROTOCOL_VERSION) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const type = message.type;
  if (connection.listener === 'agent') {
    if (type === 'register') handleRegister(state, connection, message);
    else if (type === 'event') handleEvent(state, connection, message);
    else if (type === 'history') handleHistory(state, connection, message);
    else if (type === 'command-result') handleCommandResult(state, connection, message);
    // A type that passed the listener set check but has no branch above is a
    // wiring bug, not a client capability error: fail closed as a protocol
    // violation rather than silently dropping the message. (Chosen over
    // CLOSE_CAPABILITY so removing the set check still fails the capability
    // test by assertion, not by a vacuous 4003.)
    else closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  if (type === 'subscribe') handleSubscribe(state, connection, message);
  else if (type === 'unsubscribe') handleUnsubscribe(state, connection, message);
  else if (type === 'command') handleCommand(state, connection, message);
  else if (type === 'history-request') handleHistoryRequest(state, connection, message);
  else if (type === 'start-session') handleStartSession(state, connection, message);
  else if (type === 'kill-session') handleKillSession(state, connection, message);
  else closeWith(connection, CLOSE_PROTOCOL);
}

export async function createHub(options: HubOptions): Promise<Hub> {
  const maxPayload = options.maxPayload ?? DEFAULT_MAX_PAYLOAD;
  const agent = new WebSocketServer({ host: '127.0.0.1', port: 0, maxPayload });
  // Attach the readiness promises before awaiting either: a server that starts
  // listening while we await its sibling would otherwise fire 'listening' once,
  // before the listener is attached, and hang forever.
  const agentReady = listen(agent);
  const viewer = new WebSocketServer({
    host: options.viewerHost ?? '0.0.0.0',
    port: options.viewerPort,
    maxPayload,
  });
  const viewerReady = listen(viewer);

  try {
    await Promise.all([agentReady, viewerReady]);
  } catch (error) {
    await Promise.allSettled([closeServer(agent), closeServer(viewer)]);
    throw error;
  }

  const state: State = {
    config: {
      token: options.token,
      tickets: options.tickets,
      maxAuthAttempts: options.maxAuthAttempts ?? DEFAULT_MAX_AUTH_ATTEMPTS,
      authCloseDelayMs: options.authCloseDelayMs ?? DEFAULT_AUTH_CLOSE_DELAY_MS,
      maxViewerBytes: options.maxViewerBytes ?? MAX_RELAY_BYTES,
      ...(options.spawner === undefined ? {} : { spawner: options.spawner }),
    },
    sessions: new Map(),
    viewers: new Set(),
  };

  const sockets = new Set<WebSocket>();
  for (const [server, listener] of [
    [agent, 'agent'],
    [viewer, 'viewer'],
  ] as const) {
    server.on('connection', (socket: WebSocket) => {
      sockets.add(socket);
      const connection: Connection = {
        listener,
        socket,
        budget: new ByteBudget(state.config.maxViewerBytes),
        authenticated: false,
        authAttempts: 0,
        closing: false,
        resyncAnnounced: new Set(),
      };
      if (listener === 'viewer') state.viewers.add(connection);
      socket.on('close', () => {
        sockets.delete(socket);
        state.viewers.delete(connection);
        // A closing agent retires its session and tells subscribers; a closing
        // viewer is dropped from every set it was in. A retired session changes
        // the registry, so the remaining viewers are pushed the new list.
        let retired = false;
        for (const [sessionId, session] of [...state.sessions]) {
          if (session.agent === connection) {
            retireSession(state, sessionId);
            retired = true;
          }
          session.subscribers.delete(connection);
          session.pendingHistory.delete(connection);
          for (const [id, queue] of [...session.pendingCommands]) {
            const remaining = queue.filter((viewer) => viewer !== connection);
            if (remaining.length === 0) session.pendingCommands.delete(id);
            else session.pendingCommands.set(id, remaining);
          }
        }
        if (retired) broadcastSessions(state);
      });
      // A socket error is followed by a close; the close handler is the one
      // that matters. Ignoring here keeps the process off the crash path.
      socket.on('error', () => {});
      socket.on('message', (data: RawData) => handleMessage(state, connection, data));
    });
  }

  return {
    agentPort: addressPort(agent),
    viewerPort: addressPort(viewer),
    async close(): Promise<void> {
      for (const socket of sockets) socket.terminate();
      sockets.clear();
      await Promise.all([closeServer(agent), closeServer(viewer)]);
      await state.config.spawner?.close();
    },
  };
}
