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
import { homedir } from 'node:os';
import { basename, join } from 'node:path';

import { WebSocketServer } from 'ws';
import type { RawData, WebSocket } from 'ws';

import {
  CLOSE_CAPABILITY,
  CLOSE_INTERNAL,
  CLOSE_PROTOCOL,
  CLOSE_RATE_LIMITED,
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
import type { SessionOrigin } from '../protocol/protocol.ts';
import { compareToken } from './auth.ts';
import { ByteBudget } from './backpressure.ts';
import {
  DEFAULT_MAX_DIR_BYTES,
  DEFAULT_MAX_DIR_ENTRIES,
  DEFAULT_MAX_DIR_SCAN_ENTRIES,
  canonicalizePath,
  getAgentDir,
} from './folders.ts';
import type { TicketStore } from './pairing.ts';
import type { Spawner } from './spawner.ts';
import type { Connection, Session, State } from './hub-state.ts';
import { ownedSession } from './hub-state.ts';
import { broadcastAgentSettled, broadcastSessions, closeWith, pushSessions, sendToViewer } from './hub-outbound.ts';
export { CLOSE_CAPABILITY, CLOSE_INTERNAL, CLOSE_PROTOCOL, CLOSE_RATE_LIMITED };
import { handleChildExit, removePendingByPid } from './hub-pending.ts';
import { handleCommand, handleCommandResult, handleHistory, handleHistoryRequest, handleKillSession, handleListDirs, handleStartSession, handleSubscribe, handleUnsubscribe } from './hub-commands.ts';
export { COMMAND_ALLOWLIST } from './hub-commands.ts';

const DEFAULT_MAX_AUTH_ATTEMPTS = 3;
const DEFAULT_AUTH_CLOSE_DELAY_MS = 250;
/** Deadline for a connection to authenticate before it is closed. */
const DEFAULT_AUTH_DEADLINE_MS = 10_000;
/** Most unauthenticated viewer connections accepted at once. */
const DEFAULT_MAX_UNAUTHENTICATED_VIEWERS = 64;
/** Cap on a single inbound frame; `ws` defaults to 100 MB, far too generous.
 * Exported so the contract test can pin it to `protocol/contract.json`. */
export const DEFAULT_MAX_PAYLOAD = 1024 * 1024;
/** Most outstanding commands one session may have queued. */
const DEFAULT_MAX_PENDING_COMMANDS = 128;

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
  /** Deadline for a connection to authenticate, in ms. Defaults to 10 000. */
  authDeadlineMs?: number;
  /** Max unauthenticated viewer connections accepted at once. Defaults to 64. */
  maxUnauthenticatedViewers?: number;
  /** Per-viewer budget for relayed events, in bytes. */
  maxViewerBytes?: number;
  /** Maximum size of a single inbound frame, in bytes. Defaults to 1 MiB. */
  maxPayload?: number;
  /**
   * The user's home root that listings and project cwds are contained by.
   * Defaults to `canonicalizePath($HOME ?? homedir())`.
   */
  homeDir?: string;
  /** pi's agent directory. Defaults to `getAgentDir(env, homedir())`. */
  agentDir?: string;
  /** pi's trust store. Defaults to `<agentDir>/trust.json`. */
  trustPath?: string;
  /** Max entries returned by one `list-dirs`. Defaults to 500. */
  maxDirEntries?: number;
  /** Max raw directory entries one `list-dirs` will scan. Defaults to 10 000. */
  maxDirScanEntries?: number;
  /** Max encoded bytes for one `list-dirs`. Defaults to 256 KiB. */
  maxDirBytes?: number;
  /** Most outstanding commands one session may have queued. Defaults to 128. */
  maxPendingCommands?: number;
  /** The process supervisor for app-started sessions, when one is configured. */
  spawner?: Spawner;
  /** Called when an escaped error is contained in a message handler. The hub
   *  writes no stderr itself; the CLI owns reporting. */
  onHandlerError?: (error: unknown) => void;
}

export interface Hub {
  /** The real agent-listener port (ephemeral). */
  readonly agentPort: number;
  /** The real viewer-listener port. */
  readonly viewerPort: number;
  /** Closes both listeners and terminates every open socket. */
  close(): Promise<void>;
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

function failAuth(connection: Connection, config: State['config']): void {
  connection.authAttempts += 1;
  if (connection.authAttempts < config.maxAuthAttempts) return;
  connection.closing = true;
  const timer = setTimeout(() => {
    connection.socket.close(CLOSE_RATE_LIMITED);
  }, config.authCloseDelayMs);
  timer.unref();
}

/**
 * Marks the connection authenticated and clears its deadline timer: the clear
 * (not the callback's guard) is what stops a healthy socket being closed.
 */
function markAuthenticated(connection: Connection): void {
  connection.authenticated = true;
  clearTimeout(connection.authTimer);
  connection.authTimer = undefined;
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
    markAuthenticated(connection);
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
  markAuthenticated(connection);
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
  // The child that was pending has now registered; forget its placeholder. A
  // re-register that changes nothing else must still republish, or the
  // placeholder row would stay on screen forever.
  const clearedPending = pid !== undefined && removePendingByPid(state, pid);
  const label = registerLabel(message, sessionId, origin);
  // The successor of a `/new` or `/fork` names the id it replaced; carried so
  // the app can follow the replacement instead of dropping to the session list.
  const replacesSessionId = asString(message.replaces);
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
    if (existing.label !== label || existing.origin !== origin || clearedPending) {
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
    ...(replacesSessionId === null ? {} : { replacesSessionId }),
    subscribers: new Set(),
    pendingHistory: new Map(),
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
  for (const subscriber of session.subscribers) sendToViewer(subscriber, message, session.sessionId);
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
  else if (type === 'list-dirs') handleListDirs(state, connection, message);
  else closeWith(connection, CLOSE_PROTOCOL);
}

export async function createHub(options: HubOptions): Promise<Hub> {
  const maxPayload = options.maxPayload ?? DEFAULT_MAX_PAYLOAD;
  const homeDir = options.homeDir ?? canonicalizePath(process.env.HOME ?? homedir());
  const agentDir = options.agentDir ?? getAgentDir(process.env, homedir());
  const trustPath = options.trustPath ?? join(agentDir, 'trust.json');
  const maxDirEntries = options.maxDirEntries ?? DEFAULT_MAX_DIR_ENTRIES;
  const maxDirScanEntries = options.maxDirScanEntries ?? DEFAULT_MAX_DIR_SCAN_ENTRIES;
  const maxDirBytes = options.maxDirBytes ?? DEFAULT_MAX_DIR_BYTES;
  const maxPendingCommands = options.maxPendingCommands ?? DEFAULT_MAX_PENDING_COMMANDS;
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
      authDeadlineMs: options.authDeadlineMs ?? DEFAULT_AUTH_DEADLINE_MS,
      maxUnauthenticatedViewers:
        options.maxUnauthenticatedViewers ?? DEFAULT_MAX_UNAUTHENTICATED_VIEWERS,
      maxViewerBytes: options.maxViewerBytes ?? MAX_RELAY_BYTES,
      homeDir,
      agentDir,
      trustPath,
      maxDirEntries,
      maxDirScanEntries,
      maxDirBytes,
      maxPendingCommands,
      ...(options.spawner === undefined ? {} : { spawner: options.spawner }),
      ...(options.onHandlerError === undefined ? {} : { onHandlerError: options.onHandlerError }),
    },
    sessions: new Map(),
    pendingSpawns: new Map(),
    pendingSeq: 0,
    viewers: new Set(),
  };

  if (options.spawner !== undefined) {
    state.unsubscribeChildExit = options.spawner.onChildExit((event) =>
      handleChildExit(state, event),
    );
  }

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
        if (connection.authTimer !== undefined) {
          clearTimeout(connection.authTimer);
          connection.authTimer = undefined;
        }
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
          for (const [key, group] of [...session.pendingHistory]) {
            group.delete(connection);
            if (group.size === 0) session.pendingHistory.delete(key);
          }
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
      socket.on('message', (data: RawData) => {
        try {
          handleMessage(state, connection, data);
        } catch (error) {
          // Contained to this one connection. 4500 is retryable on purpose: a
          // transient handler fault must not become permanent bridge death.
          try {
            state.config.onHandlerError?.(error);
          } catch {
            // Observability must not re-introduce the crash this guard prevents.
          }
          closeWith(connection, CLOSE_INTERNAL);
        }
      });

      // Cap check AFTER all three listeners are attached, and BEFORE the
      // deadline timer. The refused socket still gets its `close` event, so
      // the cleanup that removes it from `sockets`/`state.viewers` runs; a
      // `return` before `socket.on('close')` would leak the entry for good.
      if (
        listener === 'viewer' &&
        [...state.viewers].filter((viewer) => !viewer.authenticated).length >
          state.config.maxUnauthenticatedViewers
      ) {
        closeWith(connection, CLOSE_RATE_LIMITED);
        return;
      }

      connection.authTimer = setTimeout(() => {
        if (connection.authenticated) return;
        closeWith(connection, CLOSE_RATE_LIMITED);
      }, state.config.authDeadlineMs);
      connection.authTimer.unref();
    });
  }

  return {
    agentPort: addressPort(agent),
    viewerPort: addressPort(viewer),
    async close(): Promise<void> {
      // Unsubscribe before terminating the children: `terminate` does not
      // notify, but a racing real child `exit` during shutdown must not reach a
      // hub that is already tearing down.
      state.unsubscribeChildExit?.();
      state.unsubscribeChildExit = undefined;
      for (const socket of sockets) socket.terminate();
      sockets.clear();
      await Promise.all([closeServer(agent), closeServer(viewer)]);
      await state.config.spawner?.close();
    },
  };
}
