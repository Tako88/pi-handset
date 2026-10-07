import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { WebSocket } from 'ws';
import type { RawData } from 'ws';

// Deliberately `.ts`, and deliberately written before `hub.ts` exists: the red
// run must fail with an unresolved import, not a loader error.
import { createHub } from '../../src/hub/hub.ts';

import { createTicketStore } from '../../src/hub/pairing.ts';

import type { ChildExitEvent, ChildExitReason, Spawner } from '../../src/hub/spawner.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

export const TOKEN = 'a'.repeat(64);

export const running: Array<{ close(): Promise<void> }> = [];
export const clients: Client[] = [];
export const scratchDirs: string[] = [];

/** A temp directory to stand in for the user's home; removed in `afterEach`. */
export function scratchHome(): string {
  const dir = mkdtempSync(join(tmpdir(), 'pi-handset-hub-test-'));
  scratchDirs.push(dir);
  return dir;
}

export async function cleanup(): Promise<void> {
  // Never leak a socket or a listener: tear down clients, then hubs, even when
  // a test failed.
  for (const client of clients) {
    if (
      client.ws.readyState === WebSocket.OPEN ||
      client.ws.readyState === WebSocket.CONNECTING
    ) {
      client.ws.terminate();
    }
  }
  clients.length = 0;
  while (running.length > 0) {
    await running.pop()!.close();
  }
  for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true });
  scratchDirs.length = 0;
}

export async function startHub(
  overrides: Partial<Parameters<typeof createHub>[0]> = {},
): Promise<Awaited<ReturnType<typeof createHub>>> {
  const hub = await createHub({
    token: TOKEN,
    tickets: createTicketStore(),
    viewerPort: 0,
    viewerHost: '127.0.0.1',
    ...overrides,
  });
  running.push(hub);
  return hub;
}

/** A controllable in-process spawner; no child process is ever created. */
export interface FakeSpawner extends Spawner {
  spawnCalls: number;
  /** The options passed to each `spawn`, in call order. */
  spawnArgs: Array<{ cwd?: string; trust?: boolean } | undefined>;
  killCalls: number;
  closeCalls: number;
  confirmed: number[];
  killed: number[];
  /** Pids `owns` reports as live. */
  owned: Set<number>;
  spawnImpl: () => Promise<number>;
  closeDelayMs: number;
  /** True once `close()` has fully resolved (proves the hub awaited it). */
  closeFinished: boolean;
  /** The hub's `onChildExit` listeners, in subscription order. */
  exitListeners: Array<(event: ChildExitEvent) => void>;
  /** Fires every subscribed listener with a synthetic child exit. */
  fireExit(pid: number, reason: ChildExitReason): void;
}

export function makeFakeSpawner(): FakeSpawner {
  const fake: FakeSpawner = {
    spawnCalls: 0,
    spawnArgs: [],
    killCalls: 0,
    closeCalls: 0,
    confirmed: [],
    killed: [],
    owned: new Set<number>(),
    exitListeners: [],
    spawnImpl: async () => 4242,
    closeDelayMs: 0,
    closeFinished: false,
    async spawn(options) {
      fake.spawnCalls += 1;
      fake.spawnArgs.push(options);
      return fake.spawnImpl();
    },
    owns(pid) {
      return typeof pid === 'number' && fake.owned.has(pid);
    },
    confirm(pid) {
      fake.confirmed.push(pid);
    },
    kill(pid) {
      fake.killCalls += 1;
      fake.killed.push(pid);
    },
    onChildExit(listener) {
      fake.exitListeners.push(listener);
      return () => {
        const index = fake.exitListeners.indexOf(listener);
        if (index >= 0) fake.exitListeners.splice(index, 1);
      };
    },
    fireExit(pid, reason) {
      for (const listener of [...fake.exitListeners]) listener({ pid, reason });
    },
    async close() {
      fake.closeCalls += 1;
      if (fake.closeDelayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, fake.closeDelayMs));
      }
      fake.closeFinished = true;
    },
  };
  return fake;
}

export interface Client {
  readonly ws: WebSocket;
  readonly closed: Promise<{ code: number; reason: string }>;
  send(message: unknown): void;
  /** Resolves with the next reply message, or rejects after `timeoutMs`. */
  next(timeoutMs?: number): Promise<Record<string, unknown>>;
  /** Resolves with the next reply message, or `undefined` after `timeoutMs`. */
  tryNext(timeoutMs?: number): Promise<Record<string, unknown> | undefined>;
  /** Resolves with the next unsolicited `sessions` push, or rejects after `timeoutMs`. */
  nextSessions(timeoutMs?: number): Promise<Record<string, unknown>>;
  /** Resolves with the next `sessions` push, or `undefined` after `timeoutMs`. */
  tryNextSessions(timeoutMs?: number): Promise<Record<string, unknown> | undefined>;
  terminate(): void;
}

interface MessageQueue {
  push(message: Record<string, unknown>): void;
  next(timeoutMs: number): Promise<Record<string, unknown>>;
  tryNext(timeoutMs: number): Promise<Record<string, unknown> | undefined>;
}

/**
 * A FIFO with at most one pending waiter. `ws` delivers messages in order, so a
 * promise-based reader is enough.
 */
function messageQueue(): MessageQueue {
  const items: Record<string, unknown>[] = [];
  let waiter: ((value: Record<string, unknown>) => void) | null = null;

  function next(timeoutMs: number): Promise<Record<string, unknown>> {
    const queued = items.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        waiter = null;
        reject(new Error('timed out waiting for a message'));
      }, timeoutMs);
      waiter = (value) => {
        clearTimeout(timer);
        resolve(value);
      };
    });
  }

  return {
    push(message) {
      if (waiter !== null) {
        const resolve = waiter;
        waiter = null;
        resolve(message);
      } else {
        items.push(message);
      }
    },
    next,
    async tryNext(timeoutMs) {
      try {
        return await next(timeoutMs);
      } catch {
        return undefined;
      }
    },
  };
}

/**
 * A cross-socket barrier: `ws` auto-responds to a ping with a pong, and the
 * server processes this socket's frames in order, so once the pong round-trips
 * every message sent before it on this socket has been handled by the hub.
 */
export function barrier(client: Client): Promise<void> {
  return new Promise((resolve) => {
    client.ws.once('pong', () => resolve());
    client.ws.ping();
  });
}

/**
 * Records every inbound frame in arrival order, for tests that must assert the
 * order of two frames of different types (which the split queues hide).
 */
export function recordFrames(client: Client): Array<Record<string, unknown>> {
  const frames: Array<Record<string, unknown>> = [];
  client.ws.on('message', (data) =>
    frames.push(JSON.parse(frameText(data)) as Record<string, unknown>),
  );
  return frames;
}

/** Awaits a close, rejecting after a bound so a regression fails fast. */
export function closed(
  client: Client,
  timeoutMs = 2000,
): Promise<{ code: number; reason: string }> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('timed out waiting for the socket to close')),
      timeoutMs,
    );
    client.closed.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
      },
    );
  });
}

/**
 * Decodes a websocket frame as text. `RawData` is `Buffer | ArrayBuffer |
 * Buffer[]`, and `String(data)` on the latter two is `Object.prototype.toString`
 * ("[object ArrayBuffer]") rather than the payload. `ws` hands a server-side
 * listener a `Buffer`, so this only ever takes the first branch in practice —
 * which is exactly why it needs saying.
 */
export function frameText(data: RawData): string {
  if (Buffer.isBuffer(data)) return data.toString('utf8');
  if (Array.isArray(data)) return Buffer.concat(data).toString('utf8');
  return Buffer.from(data).toString('utf8');
}

export function connect(port: number): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const messages = messageQueue();
  const sessions = messageQueue();

  ws.on('message', (data) => {
    const message = JSON.parse(frameText(data)) as Record<string, unknown>;
    // `sessions` is unsolicited registry traffic. Keeping it out of the reply
    // queue lets a test read either stream without interleaving noise; the
    // sessions-specific tests read it explicitly via `nextSessions`.
    (message.type === 'sessions' ? sessions : messages).push(message);
  });

  const closed = new Promise<{ code: number; reason: string }>((resolve) => {
    ws.once('close', (code, reason) => resolve({ code, reason: String(reason) }));
  });

  return new Promise((resolve, reject) => {
    ws.once('error', reject);
    ws.once('open', () => {
      const client: Client = {
        ws,
        closed,
        send: (message) => ws.send(JSON.stringify(message)),
        next: (timeoutMs = 2000) => messages.next(timeoutMs),
        tryNext: (timeoutMs = 300) => messages.tryNext(timeoutMs),
        nextSessions: (timeoutMs = 2000) => sessions.next(timeoutMs),
        tryNextSessions: (timeoutMs = 300) => sessions.tryNext(timeoutMs),
        terminate: () => ws.terminate(),
      };
      clients.push(client);
      resolve(client);
    });
  });
}

// Shared hub test fakes and helpers. Not a test file (does not end .test.ts),
// so the test runner does not collect it. Each importing test file gets its own
// module instance (one process per file), so the mutable state below stays
// exactly as private as it was when it lived in the single hub test file.

export async function helloTokened(client: Client): Promise<void> {
  client.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });
  await barrier(client);
}

export interface PausableSocket {
  pause(): void;
  resume(): void;
}

/**
 * The underlying TCP socket, paused to make a viewer genuinely slow. A missing
 * `_socket` means `ws` changed its internals; say so explicitly rather than
 * failing with an opaque undefined error.
 */
export function underlyingSocket(client: Client): PausableSocket {
  const socket = (client.ws as unknown as { _socket?: PausableSocket })._socket;
  if (socket === undefined) {
    throw new Error('ws internals changed: WebSocket has no _socket to pause');
  }
  return socket;
}

/**
 * Authenticates a viewer and asserts the session list it is pushed on
 * authentication lands in the sessions queue.
 */
export async function helloViewer(client: Client): Promise<void> {
  await helloTokened(client);
  const first = await client.nextSessions(2000);
  assert.equal(first.type, 'sessions', 'a viewer is pushed the session list on auth');
}

/** A helper to read a session entry out of a `sessions` push. */
export function sessionEntry(
  push: Record<string, unknown>,
  sessionId: string,
): Record<string, unknown> {
  const sessions = push.sessions as Array<Record<string, unknown>>;
  const entry = sessions.find((session) => session.sessionId === sessionId);
  assert.ok(entry !== undefined, `no session ${sessionId} in the push`);
  return entry;
}
