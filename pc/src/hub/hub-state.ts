import type { WebSocket } from 'ws';

import type { AgentState, SessionOrigin } from '../protocol/protocol.ts';
import type { ByteBudget } from './backpressure.ts';
import type { TicketStore } from './pairing.ts';
import type { Spawner } from './spawner.ts';

type Listener = 'agent' | 'viewer';

export interface Connection {
  readonly listener: Listener;
  readonly socket: WebSocket;
  readonly budget: ByteBudget;
  authenticated: boolean;
  authAttempts: number;
  closing: boolean;
  /** Armed at connection time; cleared on auth success and on close. */
  authTimer?: NodeJS.Timeout;
  /** Session ids this viewer has been told to resync; cleared per session. */
  readonly resyncAnnounced: Set<string>;
}

export interface Session {
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
  /** The hub session id this one replaced, when its register named one. */
  replacesSessionId?: string;
  readonly subscribers: Set<Connection>;
  /**
   * Viewers awaiting a `history` reply, keyed by the request's cursor (`''` for
   * a request that carried none). Coalescing is per key: N viewers asking for
   * the same page produce one forwarded `history-request`, while different
   * cursors are forwarded separately. A group is deleted once its reply lands
   * or its last member disconnects, so the map holds one entry per outstanding
   * page, not per session.
   */
  readonly pendingHistory: Map<string, Set<Connection>>;
  /** `id` -> viewers awaiting its result, in issue order. */
  readonly pendingCommands: Map<string, Connection[]>;
}

/**
 * A spawn the hub created but that has not registered yet. `id` is hub-generated
 * and viewer-safe (`pending-<n>`); `pid` keys the spawner's exit notification.
 */
export interface PendingSpawn {
  readonly id: string;
  readonly label: string;
  readonly pid: number;
}

export interface State {
  readonly config: {
    token: string;
    tickets: TicketStore;
    maxAuthAttempts: number;
    authCloseDelayMs: number;
    authDeadlineMs: number;
    maxUnauthenticatedViewers: number;
    maxViewerBytes: number;
    homeDir: string;
    agentDir: string;
    trustPath: string;
    maxDirEntries: number;
    maxDirScanEntries: number;
    maxDirBytes: number;
    maxPendingCommands: number;
    spawner?: Spawner;
    onHandlerError?: (error: unknown) => void;
  };
  readonly sessions: Map<string, Session>;
  /** Spawns the hub created but that have not registered yet, keyed by id. */
  readonly pendingSpawns: Map<string, PendingSpawn>;
  /** Monotonic source for the viewer-safe `pending-<n>` ids. */
  pendingSeq: number;
  /** Unsubscribes this hub's `onChildExit` listener; set when a spawner exists. */
  unsubscribeChildExit?: () => void;
  /** Authenticated viewer connections; the broadcast audience for `sessions`. */
  readonly viewers: Set<Connection>;
}

/** The session this agent connection currently owns, if any. */
export function ownedSession(state: State, connection: Connection): Session | null {
  for (const session of state.sessions.values()) {
    if (session.agent === connection) return session;
  }
  return null;
}
