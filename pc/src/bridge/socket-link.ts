/** Dialing the hub, the close policy, and reconnect scheduling. */

import { CLOSE_CAPABILITY, CLOSE_PROTOCOL, CLOSE_RATE_LIMITED } from '../protocol/protocol.ts';
import type { AgentToHubMessage } from '../protocol/protocol.ts';
import { computeBackoff, RATE_LIMITED_RECONNECT_MS } from './backoff.ts';
import { encodeAgentMessage } from './wire.ts';
import type { BridgeCloseEvent, BridgeSocket, SocketFactory } from './pi-types.ts';

/** The link's lifecycle seam: session transitions, shutdown, and one frame. */
export interface SocketLink {
  startSession(): void;
  stop(): void;
  open(): void;
  send(message: AgentToHubMessage): boolean;
}

/** The injected seams. The endpoint is structural on purpose: naming the
 * extension's `BridgeEndpoint` would add a type-only cycle for two fields. */
export interface SocketLinkDeps {
  socketFactory: SocketFactory;
  resolveEndpoint: () => { url: string; token: string } | null;
  rng: () => number;
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (handle: unknown) => void;
  debug: (text: string) => void;
  guard: (run: () => void) => void;
}

/** What the link reports back: the handshake is the bridge's, not the link's. */
export interface SocketLinkCallbacks {
  onOpen(token: string): void;
  onFrame(event: unknown): void;
}

const SOCKET_OPEN = 1;

/**
 * The transport's own account of a socket failure, when the event carries one.
 * A bare `socket error` cannot tell a reset from a refused dial from a peer that
 * went away — which is the whole reason the line is written. The underlying
 * error wins: an `ErrorEvent`'s own message is the generic "WebSocket error".
 */
export function describeSocketError(event: unknown): string {
  if (typeof event !== 'object' || event === null) return '';
  const cause = (event as { error?: unknown }).error;
  if (cause instanceof Error && cause.message !== '') return `: ${cause.message}`;
  const message = (event as { message?: unknown }).message;
  if (typeof message === 'string' && message !== '') return `: ${message}`;
  return '';
}

export function createSocketLink(deps: SocketLinkDeps, callbacks: SocketLinkCallbacks): SocketLink {
  let socket: BridgeSocket | null = null;
  let attempt = 0;
  let reconnectTimer: unknown = null;
  let closed = false;

  function startSession(): void {
    closeSocket('session replaced');
    cancelReconnect();
    closed = false;
    attempt = 0;
  }

  function stop(): void {
    closed = true;
    cancelReconnect();
    closeSocket('shutdown');
  }

  function closeSocket(reason: string): void {
    const current = socket;
    socket = null;
    if (current === null) return;
    try {
      current.close(1000, reason);
    } catch {
      // Already closed; nothing to do.
    }
  }

  function cancelReconnect(): void {
    if (reconnectTimer === null) return;
    deps.clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  function open(): void {
    const endpoint = deps.resolveEndpoint();
    if (endpoint === null) {
      deps.debug('pi-handset bridge: no hub discovered\n');
      scheduleReconnect();
      return;
    }
    const current = deps.socketFactory(endpoint.url);
    socket = current;
    current.addEventListener('open', () =>
      deps.guard(() => {
        if (socket !== current) return;
        attempt = 0;
        callbacks.onOpen(endpoint.token);
      }),
    );
    current.addEventListener('message', (event) => deps.guard(() => callbacks.onFrame(event)));
    current.addEventListener('error', (event) =>
      deps.guard(() => deps.debug(`pi-handset bridge: socket error${describeSocketError(event)}\n`)),
    );
    current.addEventListener('close', (event) => deps.guard(() => onSocketClose(current, event)));
  }

  function onSocketClose(current: BridgeSocket, event: BridgeCloseEvent): void {
    if (socket !== current) return;
    socket = null;
    const code = event.code;
    deps.debug(`pi-handset bridge: socket closed (${String(code ?? 'transport')})\n`);
    // 4003 is a capability violation: a bridge bug, not a transient failure.
    // Retrying it at capped backoff would reconnect forever.
    if (code === CLOSE_CAPABILITY) return;
    // 4002 is a protocol violation — a version mismatch, malformed JSON, a missing
    // field, or an unhandled type. All are permanent producer bugs (whose side is
    // not knowable here): a retry reconnects to the same rejection forever. Stop,
    // and say why. CLOSE_INTERNAL (4500) is deliberately NOT included: that close
    // is transient and must retry.
    if (code === CLOSE_PROTOCOL) {
      deps.debug(`pi-handset bridge: protocol close ${CLOSE_PROTOCOL}; not reconnecting\n`);
      return;
    }
    // 4008 is rate-limited: the hub delayed the close deliberately, so wait a
    // longer fixed span rather than an ordinary jittered backoff step.
    if (code === CLOSE_RATE_LIMITED) {
      scheduleReconnect(RATE_LIMITED_RECONNECT_MS);
      return;
    }
    scheduleReconnect();
  }

  function scheduleReconnect(fixedDelayMs?: number): void {
    if (closed) return;
    // A pending timer already owns the next dial; scheduling a second would
    // leak the first and double-connect.
    if (reconnectTimer !== null) return;
    const delay = fixedDelayMs ?? computeBackoff(attempt, { rng: deps.rng });
    if (fixedDelayMs === undefined) attempt += 1;
    // Deliberately unguarded: a throw from `resolveEndpoint`/`socketFactory`
    // here is an uncaught timer exception, exactly as before the split.
    reconnectTimer = deps.setTimeout(() => {
      reconnectTimer = null;
      open();
    }, delay);
  }

  function send(message: AgentToHubMessage): boolean {
    if (socket === null || socket.readyState !== SOCKET_OPEN) return false;
    socket.send(encodeAgentMessage(message));
    return true;
  }

  return { startSession, stop, open, send };
}
