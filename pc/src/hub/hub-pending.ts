import { PROTOCOL_VERSION } from '../protocol/protocol.ts';
import type { SpawnFailedMessage } from '../protocol/protocol.ts';
import type { ChildExitEvent, ChildExitReason } from './spawner.ts';
import { broadcastSessions, send } from './hub-outbound.ts';
import type { PendingSpawn, State } from './hub-state.ts';

/** The pending spawn a pid belongs to, or null. */
function findPendingByPid(state: State, pid: number): PendingSpawn | null {
  for (const spawn of state.pendingSpawns.values()) {
    if (spawn.pid === pid) return spawn;
  }
  return null;
}

/** Removes the pending spawn for a pid, returning whether one was removed. */
export function removePendingByPid(state: State, pid: number): boolean {
  const pending = findPendingByPid(state, pid);
  if (pending === null) return false;
  state.pendingSpawns.delete(pending.id);
  return true;
}

/**
 * Registers a pending spawn and republishes the list. A real session id
 * collision with `pending-<n>` is negligible, and `handleKillSession` checks the
 * pending list first, so the namespace is safe either way.
 */
export function beginPendingSpawn(state: State, pid: number): void {
  const id = `pending-${++state.pendingSeq}`;
  state.pendingSpawns.set(id, { id, label: 'New session', pid });
  broadcastSessions(state);
}

/** The viewer-facing failure text for each reason a child can leave. */
const SPAWN_FAILURE_TEXT: Record<ChildExitReason, string> = {
  exit: 'the session exited before it started',
  error: 'the session failed to start',
  deadline: 'the session did not start in time',
};

function spawnFailedMessage(id: string, error: string): SpawnFailedMessage {
  return { protocolVersion: PROTOCOL_VERSION, type: 'spawn-failed', id, error };
}

/**
 * Tells every authenticated viewer a pending spawn failed, then removes the
 * placeholder. The order is load-bearing: the app ignores a failure for an id it
 * no longer holds, so the failure must arrive before the row vanishes. Both
 * frames share one socket, so their order is guaranteed. `send()` is unbudgeted
 * on purpose — a silently dropped failure would recreate exactly the bug #13 is
 * about.
 */
function broadcastSpawnFailed(
  state: State,
  pending: PendingSpawn,
  reason: ChildExitReason,
): void {
  const message = spawnFailedMessage(pending.id, SPAWN_FAILURE_TEXT[reason]);
  for (const viewer of state.viewers) {
    if (viewer.authenticated) send(viewer, message);
  }
  state.pendingSpawns.delete(pending.id);
  broadcastSessions(state);
}

/**
 * A spawned child left before it registered: if a placeholder is still holding
 * its pid, fail it to every viewer; otherwise it already registered and there is
 * nothing to say.
 */
export function handleChildExit(state: State, event: ChildExitEvent): void {
  const pending = findPendingByPid(state, event.pid);
  if (pending === null) return;
  broadcastSpawnFailed(state, pending, event.reason);
}
