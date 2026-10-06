import { PROTOCOL_VERSION, asString } from '../protocol/protocol.ts';
import {
  FolderError,
  TrustStoreError,
  hasTrustRequiringResources,
  listDirectories,
  resolveWithinHome,
  saveTrustDecision,
  trustDecision,
} from './folders.ts';
import type { DirectoryListing } from './folders.ts';
import { CLOSE_PROTOCOL, broadcastSessions, closeWith, send, sendToViewer } from './hub-outbound.ts';
import { ownedSession } from './hub-state.ts';
import type { Connection, Session, State } from './hub-state.ts';
import { beginPendingSpawn } from './hub-pending.ts';

/** The bridge's command allowlist; anything else is refused here too.
 * Exported so a test can pin it equal to the bridge's copy: the two must not
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

function commandResult(id: string, ok: boolean, error: string): unknown {
  return { protocolVersion: PROTOCOL_VERSION, type: 'command-result', id, ok, error };
}

/** An `ok` result deliberately carries no `error` field. */
function commandOk(id: string): unknown {
  return { protocolVersion: PROTOCOL_VERSION, type: 'command-result', id, ok: true };
}

/** A rejection's message, verbatim when it is not an `Error` (never dropped). */
function errorMessage(error: unknown): string {
  return String((error as Error)?.message ?? error);
}

/**
 * A viewer asks the hub to spawn a headless pi session. Answered directly to
 * the issuing connection: the result is produced locally, not by an agent
 * round-trip, so there is no per-session pending map to key it into. Two
 * viewers using the same id each receive their own reply.
 *
 * With a `cwd`, the path is re-resolved immediately before the spawn (a
 * directory that vanished between the listing and this request fails here),
 * pi's trust predicate decides whether a decision is needed, and a decision is
 * persisted only when the viewer supplied one. Any trust-store failure is loud
 * and spawns nothing.
 */
export function handleStartSession(
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
  const rawCwd = message.cwd;
  if (rawCwd === undefined) {
    spawner.spawn().then(
      (pid) => {
        sendToViewer(connection, commandOk(id), null);
        beginPendingSpawn(state, pid);
      },
      (error: unknown) =>
        sendToViewer(connection, commandResult(id, false, errorMessage(error)), null),
    );
    return;
  }
  const cwd = asString(rawCwd);
  if (cwd === null) {
    sendToViewer(connection, commandResult(id, false, 'invalid cwd'), null);
    return;
  }
  const trust = message.trust;
  if (trust !== undefined && typeof trust !== 'boolean') {
    sendToViewer(connection, commandResult(id, false, 'invalid trust'), null);
    return;
  }
  const resolved = resolveWithinHome(cwd, state.config.homeDir);
  if (resolved === null) {
    sendToViewer(
      connection,
      commandResult(id, false, `not a directory inside home: ${cwd}`),
      null,
    );
    return;
  }
  let effective = false;
  try {
    const trustRequired = hasTrustRequiringResources(resolved, state.config.homeDir);
    // pi reads lazily: a folder with no trust-requiring resources cannot be
    // broken by a malformed store, so the read is skipped there.
    const existing =
      trust !== undefined || trustRequired
        ? trustDecision(state.config.trustPath, resolved)
        : null;
    effective = trust ?? existing ?? false;
    if (trust !== undefined) {
      saveTrustDecision(state.config.trustPath, resolved, trust);
    }
  } catch (error) {
    // A malformed store is a loud failure, never a silent "no decision".
    sendToViewer(connection, commandResult(id, false, errorMessage(error)), null);
    return;
  }
  spawner.spawn({ cwd: resolved, trust: effective }).then(
    (pid) => {
      sendToViewer(connection, commandOk(id), null);
      beginPendingSpawn(state, pid);
    },
    (error: unknown) =>
      sendToViewer(connection, commandResult(id, false, errorMessage(error)), null),
  );
}

/**
 * A viewer asks for the directories under the PC user's home. Answered
 * directly, and **unbudgeted**: it is a response to an explicit request, so a
 * throttled viewer must not have it silently dropped. A bad path or a broken
 * trust store is a `command-result` failure — never a close, so a browsing
 * session survives one bad folder.
 */
export function handleListDirs(
  state: State,
  connection: Connection,
  message: Record<string, unknown>,
): void {
  const id = asString(message.id);
  if (id === null) {
    closeWith(connection, CLOSE_PROTOCOL);
    return;
  }
  const rawPath = message.path;
  let target: string | undefined;
  if (rawPath === undefined) {
    target = undefined;
  } else {
    const path = asString(rawPath);
    if (path === null) {
      sendToViewer(connection, commandResult(id, false, 'invalid path'), null);
      return;
    }
    target = path;
  }
  let listing: DirectoryListing;
  let trustRequired = false;
  let trust: boolean | null = null;
  try {
    listing = listDirectories(target, state.config.homeDir, {
      maxEntries: state.config.maxDirEntries,
      maxScanEntries: state.config.maxDirScanEntries,
      maxBytes: state.config.maxDirBytes,
    });
    trustRequired = hasTrustRequiringResources(listing.path, state.config.homeDir);
    trust = trustRequired ? trustDecision(state.config.trustPath, listing.path) : null;
  } catch (error) {
    if (error instanceof FolderError || error instanceof TrustStoreError) {
      sendToViewer(connection, commandResult(id, false, errorMessage(error)), null);
      return;
    }
    throw error;
  }
  send(connection, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'dir-listing',
    id,
    path: listing.path,
    root: listing.root,
    trust,
    trustRequired,
    entries: listing.entries,
    truncated: listing.truncated,
  });
}

/**
 * A viewer asks the hub to kill an app-started session. Only a session the
 * spawner still owns may be killed; a PC-started session is refused. Answered
 * directly to the issuing connection.
 */
export function handleKillSession(
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
  // A pending spawn has no session yet, so the pending registry is consulted
  // first. A cancel is not a failure: it is acked, the row is removed and the
  // child is killed, with no `spawn-failed`. A second viewer cancel then finds
  // neither a pending nor a session and is refused 'unknown session'.
  const pending = state.pendingSpawns.get(sessionId);
  if (pending !== undefined) {
    sendToViewer(connection, commandOk(id), null);
    state.pendingSpawns.delete(sessionId);
    broadcastSessions(state);
    state.config.spawner?.kill(pending.pid);
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

export function handleCommand(
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
    send(connection, commandResult(id, false, 'unknown command'));
    return;
  }
  const session = state.sessions.get(sessionId);
  if (session === undefined) {
    send(connection, commandResult(id, false, 'unknown session'));
    return;
  }
  // The cap counts queued ENTRIES, not distinct ids: two commands sharing an id
  // are two outstanding commands. A refusal answers the request directly and is
  // never queued or forwarded.
  if (queuedCommandCount(session) >= state.config.maxPendingCommands) {
    send(connection, commandResult(id, false, 'too many outstanding commands'));
    return;
  }
  // Keyed by (session, id) with the issuing viewer queued: two viewers using
  // the same id no longer overwrite one another.
  const queue = session.pendingCommands.get(id);
  if (queue === undefined) session.pendingCommands.set(id, [connection]);
  else queue.push(connection);
  send(session.agent, message);
}

/** Total outstanding commands queued for one session, across all ids. */
function queuedCommandCount(session: Session): number {
  let total = 0;
  for (const queue of session.pendingCommands.values()) total += queue.length;
  return total;
}

export function handleCommandResult(
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

export function handleSubscribe(
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

export function handleUnsubscribe(
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

export function handleHistory(
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
  // Route by the request token only, never by guesswork. `asString` is null for
  // both an absent cursor and an empty string, which is exactly the request key
  // the matching `history-request` used. There is deliberately no FIFO
  // fallback: `fetchHistory` (a second `sendHistory` call site on the bridge)
  // can emit a `history` that answers no pending request, and delivering it to
  // whichever group happens to be oldest would discard a viewer's loaded pages
  // or duplicate a page.
  const token = asString(message.cursor);
  const key = token ?? '';
  const group = session.pendingHistory.get(key);
  if (group === undefined) return; // answers nothing: drop it
  session.pendingHistory.delete(key);
  const snapshot: Record<string, unknown> = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'snapshot',
    sessionId,
    lastSeq: session.lastSeq,
    agentState: session.agentState,
    entries,
    truncated,
  };
  // The routing token is echoed whenever the request had one; `older` only when
  // the bridge honoured the cursor, `olderCursor` only when older entries remain.
  if (token !== null) snapshot.cursor = token;
  if (message.older === true) snapshot.older = true;
  const olderCursor = asString(message.olderCursor);
  if (olderCursor !== null) snapshot.olderCursor = olderCursor;
  // A snapshot answering a `history-request` is a control *response*, not bulk
  // relay: the viewer asked for it, so it cannot be used to push unsolicited
  // bytes, and it must not be dropped. Budgeting it caused a livelock — a
  // snapshot larger than the viewer cap was dropped, the viewer was told to
  // resync, its next request produced the same oversized snapshot, and so on.
  // Like `resync-required`, deliver it unbudgeted.
  for (const viewer of group) send(viewer, snapshot);
}

/**
 * Concurrent requests for one session are coalesced *per cursor*: the first
 * request for a given page is forwarded to the agent, later ones join its reply
 * list, so N viewers asking for the same page cannot stampede one agent. Two
 * different cursors are different pages and are forwarded separately. The
 * session's tracked `lastSeq`/`agentState` are authoritative.
 */
export function handleHistoryRequest(
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
  // `cursor` is viewer-supplied and forwarded, so a present non-string is a
  // protocol violation — the hub does not run the codec on viewer frames, so it
  // is validated by hand like `sinceSeq` above.
  if (message.cursor !== undefined && typeof message.cursor !== 'string') {
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
  // An empty string is treated as no cursor (`asString('')` is null): it keys
  // the no-cursor group and is not forwarded, so it degrades to a baseline.
  const cursor = asString(message.cursor);
  const key = cursor ?? '';
  connection.resyncAnnounced.delete(sessionId);
  const group = session.pendingHistory.get(key);
  if (group !== undefined) {
    group.add(connection);
    return;
  }
  session.pendingHistory.set(key, new Set([connection]));
  const forwarded: Record<string, unknown> = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId,
  };
  if (sinceSeq !== undefined) forwarded.sinceSeq = sinceSeq;
  if (cursor !== null) forwarded.cursor = cursor;
  send(session.agent, forwarded);
}
