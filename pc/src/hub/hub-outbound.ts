import { WebSocket } from 'ws';

import { HUB_CAPABILITIES, PROTOCOL_VERSION } from '../protocol/protocol.ts';
import type { AgentSettledMessage, SessionsMessage } from '../protocol/protocol.ts';
import type { Connection, Session, State } from './hub-state.ts';

export function send(connection: Connection, message: unknown): void {
  if (connection.socket.readyState !== WebSocket.OPEN) return;
  connection.socket.send(JSON.stringify(message));
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
  const pending = [...state.pendingSpawns.values()].map((spawn) => ({
    id: spawn.id,
    label: spawn.label,
  }));
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
        // Absent rather than `undefined`: an old app compares nothing here, but
        // every existing test's exact deep-equal must not grow a phantom key.
        ...(session.replacesSessionId === undefined
          ? {}
          : { replacesSessionId: session.replacesSessionId }),
      })),
    // Absent when there are none (the common case), so an old app's exact
    // comparisons and the auth push are unchanged.
    ...(pending.length === 0 ? {} : { pending }),
    // Advertised so a viewer can gate folder browsing on it; a pre-capabilities
    // hub omits the field, and the app then never sends the new frames.
    capabilities: [...HUB_CAPABILITIES],
  };
}

/** Pushes the current list to one connection. Viewer-only by construction. */
export function pushSessions(state: State, connection: Connection): void {
  if (connection.listener !== 'viewer') return;
  sendToViewer(connection, sessionsMessage(state), null);
}

/** Pushes the current list to every authenticated viewer. */
export function broadcastSessions(state: State): void {
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
export function broadcastAgentSettled(
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
export function sendToViewer(
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

export function closeWith(connection: Connection, code: number, reason?: string): void {
  connection.closing = true;
  connection.socket.close(code, reason);
}
