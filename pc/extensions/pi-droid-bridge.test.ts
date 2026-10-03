/**
 * The pi bridge extension, driven against a stub `ExtensionAPI` and a fake
 * socket. Nothing here dials: the socket factory is injected, the clock is
 * injected, the RNG is injected, and the debug sink is injected.
 *
 * The tests are grouped by behaviour:
 * - normalization is total and explicit over the real `AssistantMessageEvent` list
 * - agent state is terminal on `agent_settled`, never on `agent_end`
 * - the command allowlist dispatches, everything else is refused
 * - reconnect is capped and jittered
 * - mode guard, silence, and lifecycle
 */

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, beforeEach } from 'node:test';

import {
  EVENT_PAYLOAD_KINDS,
  HISTORY_MAX_BYTES,
  MAX_RELAY_BYTES,
  PROTOCOL_VERSION,
  TOOL_VIEW_MAX_BYTES,
  type CommandView,
  type DiffView,
  type FileView,
  type GenericView,
  type MatchesView,
  type SlashCommand,
  type ToolPayload,
  type TreeNodeSummary,
} from '../src/protocol/protocol.ts';
import { writeDiscovery } from '../src/hub/discovery.ts';
import { loadOrCreateToken } from '../src/hub/auth.ts';
// Test-only coupling: the hub's copy of the allowlist is asserted equal to the
// bridge's so drift fails cheaply instead of only at the real-pi capstone.
import { COMMAND_ALLOWLIST as HUB_COMMAND_ALLOWLIST } from '../src/hub/hub.ts';

// Deliberately `.ts`, and deliberately written before the module exists: the
// red run must fail with an unresolved import, not a loader error.
import {
  RATE_LIMITED_RECONNECT_MS,
  COMMAND_ALLOWLIST as BRIDGE_COMMAND_ALLOWLIST,
  COMMAND_NOT_ALLOWED,
  SESSION_COMMAND_NAME,
  SETTLED_TEXT_MAX_CODE_POINTS,
  annotateToolViews,
  boundToolPayload,
  buildToolView,
  computeBackoff,
  installBridge,
  isActiveMode,
  normalizeAssistantEvent,
  normalizeMessageEnd,
  projectHistory,
  projectTree,
  readEndpoint,
  resetSessionLinkageForTests,
  settleText,
  toolCallPayloads,
  toolResultPayload,
  TOOL_VIEW_MAX_LINES,
} from './pi-droid-bridge.ts';
import type {
  AssistantMessageEvent,
  BridgeCloseEvent,
  BridgeCommandCtx,
  BridgeCtx,
  BridgeDeps,
  BridgeHandler,
  BridgeModel,
  BridgePi,
  BridgeSocket,
  MessageEndEvent,
  UserMessageContent,
} from './pi-droid-bridge.ts';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class FakeSocket implements BridgeSocket {
  readyState = 0;
  readonly sent: string[] = [];
  readonly closeCalls: Array<{ code?: number; reason?: string }> = [];
  private readonly listeners = new Map<string, Array<(event: any) => void>>();

  send(data: string): void {
    this.sent.push(data);
  }

  close(code?: number, reason?: string): void {
    this.closeCalls.push({ code, reason });
    this.readyState = 3;
    this.dispatch('close', { code, reason });
  }

  addEventListener(type: 'close', handler: (event: BridgeCloseEvent) => void): void;
  addEventListener(type: string, handler: (event: unknown) => void): void;
  addEventListener(type: string, handler: (event: any) => void): void {
    const list = this.listeners.get(type) ?? [];
    list.push(handler);
    this.listeners.set(type, list);
  }

  open(): void {
    this.readyState = 1;
    this.dispatch('open', {});
  }

  message(object: unknown): void {
    this.dispatch('message', { data: JSON.stringify(object) });
  }

  drop(code?: number, reason?: string): void {
    this.readyState = 3;
    this.dispatch('close', { code, reason });
  }

  private dispatch(type: string, event: unknown): void {
    for (const handler of this.listeners.get(type) ?? []) handler(event);
  }
}

class StubPi implements BridgePi {
  readonly handlers = new Map<string, BridgeHandler>();
  readonly userMessages: Array<{ content: UserMessageContent; options?: { deliverAs?: string } }> = [];
  readonly models: unknown[] = [];
  readonly thinkingLevels: string[] = [];
  readonly sessionNames: string[] = [];
  modelAccepted = true;
  /** When set, `setModel` throws it — the inner pi throw the wrapper propagates. */
  modelError?: Error;
  /** pi's command list, in the shape pi returns (extra fields included). The
   * bridge must forward only name/description. */
  commands: Array<{ name: string; description?: string; source?: string; sourceInfo?: unknown }> = [];
  /** A false value models an older pi with no `getCommands` at all. */
  commandsAvailable = true;
  /** Commands the bridge registered, in registration order. */
  readonly registeredCommands: Array<{
    name: string;
    options: { description?: string; handler: (args: string, ctx: BridgeCommandCtx) => unknown };
  }> = [];
  private sessionName: string | undefined;

  on(event: string, handler: BridgeHandler): () => void {
    this.handlers.set(event, handler);
    return () => this.handlers.delete(event);
  }

  sendUserMessage(content: UserMessageContent, options?: { deliverAs?: 'steer' | 'followUp' }): void {
    this.userMessages.push({ content, options });
  }

  async setModel(model: unknown): Promise<boolean> {
    if (this.modelError !== undefined) throw this.modelError;
    this.models.push(model);
    return this.modelAccepted;
  }

  setThinkingLevel(level: string): void {
    this.thinkingLevels.push(level);
  }

  setSessionName(name: string): void {
    this.sessionNames.push(name);
    this.sessionName = name;
  }

  getSessionName(): string | undefined {
    return this.sessionName;
  }

  getCommands(): SlashCommand[] {
    // The bridge reads this through `this.pi.getCommands?.()`, so `undefined`
    // here is exactly the "pi exposes no command list" state it must refuse.
    return this.commandsAvailable
      ? this.commands
      : (undefined as unknown as SlashCommand[]);
  }

  registerCommand(
    name: string,
    options: { description?: string; handler: (args: string, ctx: BridgeCommandCtx) => unknown },
  ): void {
    this.registeredCommands.push({ name, options });
  }
}

/**
 * The command context pi passes a registered command's handler. Records every
 * method call and models pi's `assertActive`: for `newSession`/`fork` the second
 * call on a stale context throws, exactly as pi does. `navigateTree` does not
 * invalidate the ctx in pi, so the stub is deliberately stricter for `tree`:
 * the handler must still act exactly once and return.
 */
class StubCommandCtx implements BridgeCommandCtx {
  readonly calls: string[] = [];
  private cancelled = false;
  private error: unknown;
  private used = false;

  private act(method: string): { cancelled: boolean } {
    if (this.used) throw new Error(`command context is stale on ${method}`);
    this.used = true;
    this.calls.push(method);
    if (this.error !== undefined) throw this.error;
    return { cancelled: this.cancelled };
  }

  async newSession(): Promise<{ cancelled: boolean }> {
    return this.act('newSession');
  }

  async fork(entryId: string): Promise<{ cancelled: boolean }> {
    void entryId;
    return this.act('fork');
  }

  async navigateTree(targetId: string): Promise<{ cancelled: boolean }> {
    void targetId;
    return this.act('navigateTree');
  }

  setCancel(value: boolean): void {
    this.cancelled = value;
  }

  setThrow(error: unknown): void {
    this.error = error;
  }
}

interface TestCtx extends BridgeCtx {
  aborts(): number;
  compacts(): number;
  /** How many times the bridge asked pi for context usage. */
  usageCalls(): number;
  setUsage(usage: { tokens: number | null; contextWindow: number } | undefined): void;
  /** Drive `isIdle()` for the next dispatch. */
  setIdle(idle: boolean): void;
  /** Make `isIdle()` throw, as a stale runner would. */
  setIdleError(error: unknown): void;
  /** Replace the registry's available list (credentials and extra fields included). */
  setAvailable(models: unknown[]): void;
  /** Delete the registry, modelling an older pi with no `ctx.modelRegistry`. */
  removeRegistry(): void;
  /** Replace the session entries (history/annotation tests). */
  setEntries(entries: unknown[]): void;
  /**
   * Give the fake manager a `buildContextEntries` closure. Absent by default on
   * purpose, so every existing history test keeps exercising the whole-file
   * `getEntries()` fallback an older pi takes.
   */
  setBranchEntries(entries: unknown[]): void;
  /** Point the manager at another hub session id, as a replacement does. */
  setSessionId(id: string): void;
  /** Replace pi's session tree (listTree tests). */
  setTree(nodes: unknown[]): void;
  /** Set the tree's current leaf (`getLeafId()`; `null` is the root). */
  setLeafId(id: string | null): void;
}

function makeCtx(mode = 'tui', sessionId = 'sess-1'): TestCtx {
  let aborts = 0;
  let compacts = 0;
  let usageCalls = 0;
  let idle = true;
  let idleError: unknown;
  let currentSessionId = sessionId;
  let available: unknown[] = [{ provider: 'test-provider', id: 'test-model', name: 'Test Model' }];
  let entries: unknown[] = [{ type: 'message', id: 'e1' }];
  let leaf: string | null = null;
  // A small real-shaped tree: `{entry, children, label?}`, exactly what pi's
  // `sessionManager.getTree()` returns. Tests replace it wholesale.
  let tree: unknown[] = [
    {
      entry: { type: 'message', id: 't1', message: { role: 'user', content: 'hello' } },
      children: [],
    },
  ];
  let usage: { tokens: number | null; contextWindow: number } | undefined = {
    tokens: 23400,
    contextWindow: 128000,
  };
  const ctx: TestCtx = {
    mode,
    cwd: '/work',
    model: { id: 'test-model', provider: 'test-provider', name: 'Test Model' },
    thinkingLevel: 'medium',
    modelRegistry: {
      getAvailable: () => available,
      find: (provider, modelId) =>
        available.find(
          (entry) =>
            (entry as { provider?: unknown }).provider === provider &&
            (entry as { id?: unknown }).id === modelId,
        ),
    },
    sessionManager: {
      getSessionId: () => currentSessionId,
      getSessionFile: () => `/sessions/${currentSessionId}.jsonl`,
      getEntries: () => entries,
      getEntry: (id: string) =>
        entries.find((entry) => (entry as { id?: unknown }).id === id),
      getTree: () => tree,
      getLeafId: () => leaf,
    },
    abort: () => {
      aborts += 1;
    },
    compact: () => {
      compacts += 1;
    },
    isIdle: () => {
      if (idleError !== undefined) throw idleError;
      return idle;
    },
    getContextUsage: () => {
      usageCalls += 1;
      return usage;
    },
    aborts: () => aborts,
    compacts: () => compacts,
    usageCalls: () => usageCalls,
    setUsage: (next) => {
      usage = next;
    },
    setIdle: (next) => {
      idle = next;
    },
    setIdleError: (err) => {
      idleError = err;
    },
    setAvailable: (next) => {
      available = next;
    },
    removeRegistry: () => {
      delete ctx.modelRegistry;
    },
    setEntries: (next) => {
      entries = next;
    },
    setBranchEntries: (next) => {
      // The manager omits `buildContextEntries` until this is called, so every
      // existing history test keeps exercising the `getEntries()` fallback.
      ctx.sessionManager.buildContextEntries = () => next;
    },
    setSessionId: (next) => {
      currentSessionId = next;
    },
    setTree: (next) => {
      tree = next;
    },
    setLeafId: (next) => {
      leaf = next;
    },
  };
  return ctx;
}

interface Harness {
  pi: StubPi;
  sockets: FakeSocket[];
  writes: Array<{ stream: string; text: string }>;
  timers: Array<{ fn: () => void; ms: number }>;
  startCtx: TestCtx;
  start(mode?: string, sessionId?: string, reason?: string): TestCtx;
  /**
   * Performs a real session replacement: pi re-runs the extension factory, so
   * the successor is a NEW bridge instance sharing only the module-level
   * linkage. Models that by calling `installBridge` a second time on the same
   * stub, rather than re-firing `session_start` on the existing instance.
   */
  reinstall(): void;
  fireTimer(index?: number): void;
}

function makeHarness(overrides: Partial<BridgeDeps> = {}): Harness {
  const pi = new StubPi();
  const sockets: FakeSocket[] = [];
  const writes: Array<{ stream: string; text: string }> = [];
  const timers: Array<{ fn: () => void; ms: number }> = [];
  let startCtx = makeCtx();
  const deps: BridgeDeps = {
    env: {},
    socketFactory: (url) => {
      void url;
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket;
    },
    resolveEndpoint: () => ({ url: 'ws://127.0.0.1:1234', token: 'tok' }),
    write: (stream, text) => writes.push({ stream, text }),
    rng: () => 0.5,
    setTimeout: (fn, ms) => {
      timers.push({ fn, ms });
      return timers.length;
    },
    clearTimeout: () => {},
    ...overrides,
  };
  installBridge(pi, deps);

  const start = (mode = 'tui', sessionId = 'sess-1', reason = 'startup'): TestCtx => {
    startCtx = makeCtx(mode, sessionId);
    pi.handlers.get('session_start')!({ type: 'session_start', reason }, startCtx);
    return startCtx;
  };

  return {
    pi,
    sockets,
    writes,
    timers,
    get startCtx() {
      return startCtx;
    },
    start,
    reinstall: () => installBridge(pi, deps),
    fireTimer: (index = 0) => timers[index]!.fn(),
  };
}

// The module-level predecessor survives across bridge instances by design, so a
// unit test must not inherit a linkage recorded by an earlier one.
beforeEach(() => resetSessionLinkageForTests());

function parsed(socket: FakeSocket): Array<Record<string, unknown>> {
  return socket.sent.map((text) => JSON.parse(text) as Record<string, unknown>);
}

function tick(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

async function sendCommand(
  _pi: StubPi,
  socket: FakeSocket,
  name: string,
  args?: unknown,
): Promise<void> {
  socket.message({ protocolVersion: PROTOCOL_VERSION, type: 'command', id: `c-${name}`, sessionId: 'sess-1', name, args });
  await tick();
}

// ---------------------------------------------------------------------------
// The real AssistantMessageEvent variant list (pi-ai/dist/types.d.ts).
// ---------------------------------------------------------------------------

const REAL_VARIANTS = [
  'start',
  'text_start',
  'text_delta',
  'text_end',
  'thinking_start',
  'thinking_delta',
  'thinking_end',
  'toolcall_start',
  'toolcall_delta',
  'toolcall_end',
  'done',
  'error',
] as const;

function sampleAssistantEvent(type: string): AssistantMessageEvent {
  const partial = { role: 'assistant', content: [] };
  switch (type) {
    case 'start':
      return { type: 'start', partial };
    case 'text_start':
      return { type: 'text_start', contentIndex: 0, partial };
    case 'text_delta':
      return { type: 'text_delta', contentIndex: 0, delta: 'hello', partial };
    case 'text_end':
      return { type: 'text_end', contentIndex: 0, content: 'hello', partial };
    case 'thinking_start':
      return { type: 'thinking_start', contentIndex: 0, partial };
    case 'thinking_delta':
      return { type: 'thinking_delta', contentIndex: 0, delta: 'hmm', partial };
    case 'thinking_end':
      return { type: 'thinking_end', contentIndex: 0, content: 'hmm', partial };
    case 'toolcall_start':
      return { type: 'toolcall_start', contentIndex: 0, partial };
    case 'toolcall_delta':
      return { type: 'toolcall_delta', contentIndex: 0, delta: '{}', partial };
    case 'toolcall_end':
      return {
        type: 'toolcall_end',
        contentIndex: 0,
        toolCall: { id: 't1', name: 'bash', arguments: {} },
        partial,
      };
    case 'done':
      return { type: 'done', reason: 'stop', message: { role: 'assistant', content: [] } };
    case 'error':
      return { type: 'error', reason: 'error', error: { errorMessage: 'boom' } };
    default:
      throw new Error(`no sample for ${type}`);
  }
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

test('a text_delta normalizes to a stream payload carrying the delta and the seq', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('text_delta'), 7);
  assert.deepEqual(result, { kind: 'emit', payload: { kind: 'stream', seq: 7, text: 'hello' } });
});

test('a done event normalizes to a message payload', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('done'), 1);
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal(result.payload.kind, 'message');
});

test('an error event normalizes to a status payload', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('error'), 1);
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal(result.payload.kind, 'status');
  assert.equal((result.payload as { message?: string }).message, 'boom');
});

test('every real AssistantMessageEvent variant is explicitly emitted or ignored', () => {
  for (const type of REAL_VARIANTS) {
    const result = normalizeAssistantEvent(sampleAssistantEvent(type), 1);
    assert.ok(
      result.kind === 'emit' || result.kind === 'ignore',
      `${type} returned neither emit nor ignore: ${JSON.stringify(result)}`,
    );
    if (result.kind === 'emit') {
      assert.ok(
        (EVENT_PAYLOAD_KINDS as readonly string[]).includes(result.payload.kind),
        `${type} emitted an unknown payload kind`,
      );
    } else {
      assert.ok(result.reason.length > 0, `${type} was ignored without a stated reason`);
    }
  }
});

test('thinking_delta streams its chunk, tagged with the thinking phase', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('thinking_delta'), 1);
  assert.deepEqual(result, {
    kind: 'emit',
    payload: { kind: 'stream', seq: 1, text: 'hmm', phase: 'thinking' },
  });
});

test('thinking_end emits nothing: the committed message is authoritative', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('thinking_end'), 1);
  assert.equal(result.kind, 'ignore');
  if (result.kind !== 'ignore') return;
  assert.equal(result.reason, 'thinking-end-committed-message-authoritative');
});

test('thinking_start emits a content-free phase frame with no reasoning text', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('thinking_start'), 4);
  assert.deepEqual(result, {
    kind: 'emit',
    payload: { kind: 'stream', seq: 4, phase: 'thinking' },
  });
  if (result.kind !== 'emit') return;
  // The whole point of the phase frame: it signals liveness without carrying a
  // single byte of reasoning. A `text` field of any value must fail this.
  assert.equal('text' in (result.payload as Record<string, unknown>), false);
});

test('toolcall_delta is explicitly ignored, not silently dropped', () => {
  const result = normalizeAssistantEvent(sampleAssistantEvent('toolcall_delta'), 1);
  assert.equal(result.kind, 'ignore');
});

test('an unrecognized assistant event is explicitly ignored, never undefined', () => {
  const future = { type: 'future_variant' } as unknown as AssistantMessageEvent;
  const result = normalizeAssistantEvent(future, 1);
  assert.equal(result.kind, 'ignore');
  assert.match((result as { reason: string }).reason, /future_variant/);
});

test('a small done message is forwarded whole and not flagged truncated', () => {
  const message = { role: 'assistant', content: 'hi' };
  const result = normalizeAssistantEvent({ type: 'done', reason: 'stop', message }, 1);
  assert.deepEqual(result, { kind: 'emit', payload: { kind: 'message', message, truncated: false } });
});

test('an oversized done message is truncated and flagged, staying under the shared cap', () => {
  const huge = { role: 'assistant', content: 'x'.repeat(MAX_RELAY_BYTES + 1) };
  const result = normalizeAssistantEvent({ type: 'done', reason: 'stop', message: huge }, 1);
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal(result.payload.kind, 'message');
  assert.equal((result.payload as { truncated?: boolean }).truncated, true);
  const encoded = JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'event', payload: result.payload });
  assert.ok(
    Buffer.byteLength(encoded) <= MAX_RELAY_BYTES,
    'a truncated done event must fit the shared byte cap',
  );
});

// ---------------------------------------------------------------------------
// message_end — real pi's assistant-completion signal
// ---------------------------------------------------------------------------

test('a message_end carrying an assistant message emits exactly one message payload', () => {
  const message = { role: 'assistant', content: [{ type: 'text', text: 'hi' }] };
  const event: MessageEndEvent = { type: 'message_end', message };
  const result = normalizeMessageEnd(event);
  assert.deepEqual(result, {
    kind: 'emit',
    payload: { kind: 'message', message, truncated: false },
  });
});

test('a message_end carrying a user message is relayed as an own message', () => {
  const message = { role: 'user', content: 'hi' };
  const result = normalizeMessageEnd({ type: 'message_end', message });
  assert.deepEqual(result, {
    kind: 'emit',
    payload: { kind: 'message', message, truncated: false },
  });
});

test('a message_end carrying a toolResult message is relayed', () => {
  const message = {
    role: 'toolResult',
    toolCallId: 'call-1',
    toolName: 'read',
    content: [{ type: 'text', text: 'file body' }],
    isError: false,
  };
  const result = normalizeMessageEnd({ type: 'message_end', message });
  assert.deepEqual(result, {
    kind: 'emit',
    payload: { kind: 'message', message, truncated: false },
  });
});

test('a message_end carrying a custom message is ignored with a stated reason', () => {
  const result = normalizeMessageEnd({ type: 'message_end', message: { role: 'custom', content: 'x' } });
  assert.equal(result.kind, 'ignore');
  if (result.kind !== 'ignore') return;
  assert.match(result.reason, /custom/);
});

test('a message_end carrying a system message is ignored with a stated reason', () => {
  const result = normalizeMessageEnd({ type: 'message_end', message: { role: 'system', content: 'prompt' } });
  assert.equal(result.kind, 'ignore');
  if (result.kind !== 'ignore') return;
  assert.match(result.reason, /system/);
});

test('an oversized assistant message_end is truncated and flagged, staying under the shared cap', () => {
  const huge = { role: 'assistant', content: [{ type: 'text', text: 'x'.repeat(MAX_RELAY_BYTES + 1) }] };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal(result.payload.kind, 'message');
  assert.equal((result.payload as { truncated?: boolean }).truncated, true);
  const encoded = JSON.stringify({
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: result.payload,
  });
  assert.ok(
    Buffer.byteLength(encoded) <= MAX_RELAY_BYTES,
    'a truncated message_end must fit the shared byte cap',
  );
});

test('an oversized toolResult message_end is replaced by a byte-count marker', () => {
  const huge = {
    role: 'toolResult',
    toolCallId: 'call-1',
    toolName: 'read',
    content: [{ type: 'text', text: 'x'.repeat(MAX_RELAY_BYTES + 1) }],
    isError: false,
  };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal((result.payload as { truncated?: boolean }).truncated, true);
  assert.deepEqual((result.payload as { message?: unknown }).message, {
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(huge)),
  });
});

// ---------------------------------------------------------------------------
// In-place image-part trim (#32)
// ---------------------------------------------------------------------------
// A message oversized only because of an image part is trimmed in place: the
// image becomes `{type:'image',truncated:true,bytes}` and the message keeps its
// role and text. A message that cannot be rescued that way (text alone busts
// the cap, no trimmable part, or too many parts) keeps the whole-message marker
// as the fallback.

/** One image content part carrying `size` bytes of fake base64. */
function imagePart(size: number, mimeType = 'image/png'): Record<string, unknown> {
  return { type: 'image', data: 'A'.repeat(size), mimeType };
}

test('an oversized image part is replaced in place and the text survives', () => {
  const image = imagePart(MAX_RELAY_BYTES + 1);
  const huge = { role: 'user', content: [{ type: 'text', text: 'look at this' }, image] };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  assert.equal(result.payload.kind, 'message');
  const payload = result.payload as unknown as {
    message: { role?: string; content?: unknown[] };
    truncated?: boolean;
  };
  assert.equal(payload.truncated, true);
  assert.equal(payload.message.role, 'user');
  assert.deepEqual(payload.message.content?.[0], { type: 'text', text: 'look at this' });
  assert.deepEqual(payload.message.content?.[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(image)),
  });
  // Bounded to the MESSAGE cap only (R1 policy (a)): the hub budgets the whole
  // frame, and a message at the cap makes an over-budget frame. Asserting the
  // encoded frame fits would be false near the cap, so it is deliberately not
  // asserted here.
  assert.ok(
    Buffer.byteLength(JSON.stringify(payload.message)) <= MAX_RELAY_BYTES,
    'the trimmed message must serialize within the shared cap',
  );
});

test('an oversized assistant message_end keeps its role and text', () => {
  const image = imagePart(MAX_RELAY_BYTES + 1, 'image/jpeg');
  const huge = { role: 'assistant', content: [{ type: 'text', text: 'here' }, image] };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as unknown as {
    message: { role?: string; content?: unknown[] };
    truncated?: boolean;
  };
  assert.equal(payload.truncated, true);
  assert.equal(payload.message.role, 'assistant');
  assert.deepEqual(payload.message.content?.[0], { type: 'text', text: 'here' });
  assert.deepEqual(payload.message.content?.[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(image)),
  });
});

test('only the image parts it takes to fit are trimmed', () => {
  const big = imagePart(200_000);
  const small = imagePart(100_000);
  const huge = { role: 'user', content: [{ type: 'text', text: 'hi' }, big, small] };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as unknown as { message: { content?: unknown[] } };
  const content = payload.message.content ?? [];
  assert.equal(content.length, 3);
  // Largest first: the 200 KB part goes, the 100 KB part stays intact, and
  // exactly one part carries the marker.
  assert.deepEqual(content[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(big)),
  });
  assert.deepEqual(content[2], small);
  assert.equal(content.filter((part) => (part as { truncated?: boolean }).truncated === true).length, 1);
});

test('a toolResult message with an oversized image keeps its text', () => {
  const image = imagePart(MAX_RELAY_BYTES + 1);
  const huge = {
    role: 'toolResult',
    toolCallId: 'call-1',
    toolName: 'read',
    content: [{ type: 'text', text: 'file body' }, image],
    isError: false,
  };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as unknown as { message: { role?: string; content?: unknown[] } };
  assert.equal(payload.message.role, 'toolResult');
  assert.deepEqual(payload.message.content?.[0], { type: 'text', text: 'file body' });
  assert.deepEqual(payload.message.content?.[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(image)),
  });
});

// PIN: green today. NC-5b removes the whole-message fallback.
test('an oversized text-only message still falls back to the whole-message marker', () => {
  const huge = { role: 'assistant', content: [{ type: 'text', text: 'x'.repeat(MAX_RELAY_BYTES + 1) }] };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as { message?: unknown; truncated?: boolean };
  assert.equal(payload.truncated, true);
  assert.deepEqual(payload.message, { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) });
});

// PIN: green today. NC-5b removes the whole-message fallback.
test('a message whose own text busts the cap falls back to the marker', () => {
  const huge = {
    role: 'user',
    content: [{ type: 'text', text: 'x'.repeat(MAX_RELAY_BYTES + 1) }, imagePart(4)],
  };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as { message?: unknown };
  assert.deepEqual(payload.message, { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) });
});

// PIN: green today. NC-5c removes the `bytes <= maxBytes` early-return in
// `boundMessage`, forcing this already-fitting message down the trim path:
// nothing is trimmed, `trimmed === false`, and the whole-message marker is
// returned. Observed red: `payload.truncated` expected false, actual true
// (`true !== false` at the `assert.equal(payload.truncated, false)` line).
test('a small message with a small image is forwarded byte-for-byte', () => {
  const small = { role: 'user', content: [{ type: 'text', text: 'hi' }, imagePart(4)] };
  const result = normalizeMessageEnd({ type: 'message_end', message: small });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as { message?: unknown; truncated?: boolean };
  assert.equal(payload.truncated, false);
  assert.deepEqual(payload.message, small);
});

// PIN: green today. NC-5b removes the whole-message fallback.
test('a message with a non-string image data part and oversized text falls back to the whole marker', () => {
  const huge = {
    role: 'user',
    content: [{ type: 'text', text: 'x'.repeat(MAX_RELAY_BYTES + 1) }, { type: 'image', data: 123 }],
  };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as { message?: unknown };
  assert.deepEqual(payload.message, { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) });
});

// PIN: green today. NC-10 raises TRIM_MAX_ITERATIONS past the bound.
test('a message with more image parts than the trim bound falls back to the whole message marker', () => {
  // Each part must be large enough that more than TRIM_MAX_ITERATIONS (64) of
  // them have to go before the message fits: after 64 trims, the 6 remaining
  // 50 KB parts still exceed the cap, so the loop hits its bound and the whole
  // marker is the fallback. (With the parts too small the loop would succeed
  // well inside the bound and this pin would be vacuous.)
  const parts = Array.from({ length: 70 }, () => imagePart(50_000));
  const huge = { role: 'user', content: parts };
  const result = normalizeMessageEnd({ type: 'message_end', message: huge });
  assert.equal(result.kind, 'emit');
  if (result.kind !== 'emit') return;
  const payload = result.payload as { message?: unknown };
  assert.deepEqual(payload.message, { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) });
});

test('an oversized toolResult message_end still emits its bounded tool frame alongside the trimmed message', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const image = imagePart(MAX_RELAY_BYTES + 1);
  const original = {
    role: 'toolResult',
    toolCallId: 'call-1',
    toolName: 'read',
    content: [{ type: 'text', text: 'file body' }, image],
    isError: false,
  };
  harness.pi.handlers.get('message_end')!({ type: 'message_end', message: original }, harness.startCtx);
  const frames = parsed(socket).slice(before);
  const messageFrame = frames.find((m) => (m.payload as { kind?: string })?.kind === 'message');
  assert.ok(messageFrame, 'the trimmed message must be relayed');
  const payload = messageFrame.payload as { message: { role?: string; content?: unknown[] } };
  assert.equal(payload.message.role, 'toolResult');
  assert.deepEqual(payload.message.content?.[0], { type: 'text', text: 'file body' });
  assert.deepEqual(payload.message.content?.[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(image)),
  });
  // The tool frame is built from the ORIGINAL message (onMessageEnd's
  // `original`), never the trimmed payload; it has its own bound and an image
  // read degrades to a generic view, so it stays small.
  const toolFrame = frames.find((m) => (m.payload as { kind?: string })?.kind === 'tool');
  assert.ok(toolFrame, 'the tool frame must still be emitted');
  assert.equal((toolFrame.payload as { toolCallId?: string }).toolCallId, 'call-1');
});

test('the message_end handler relays assistant, user and toolResult messages and ignores other roles', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const handler = harness.pi.handlers.get('message_end')!;
  const assistant = { role: 'assistant', content: [{ type: 'text', text: 'done' }] };
  const user = { role: 'user', content: 'hi' };
  const toolResult = {
    role: 'toolResult',
    toolCallId: 'call-1',
    toolName: 'read',
    content: [{ type: 'text', text: 'file body' }],
    isError: false,
  };
  handler({ type: 'message_end', message: user }, harness.startCtx);
  handler({ type: 'message_end', message: assistant }, harness.startCtx);
  handler({ type: 'message_end', message: toolResult }, harness.startCtx);
  handler({ type: 'message_end', message: { role: 'system', content: 'prompt' } }, harness.startCtx);
  const emitted = parsed(socket)
    .slice(before)
    .filter((m) => (m.payload as { kind?: string })?.kind === 'message');
  // Per-role, not a single total: each relayed role must appear exactly once.
  assert.equal(emitted.length, 3, 'exactly one user, assistant and toolResult message must be relayed');
  const roles = emitted.map((m) => (m.payload as { message: { role: string } }).message.role);
  assert.deepEqual(roles, ['user', 'assistant', 'toolResult']);
  assert.deepEqual(emitted[0]!.payload, { kind: 'message', message: user, truncated: false });
  assert.deepEqual(emitted[1]!.payload, { kind: 'message', message: assistant, truncated: false });
  assert.deepEqual(emitted[2]!.payload, { kind: 'message', message: toolResult, truncated: false });
});

test('consecutive text deltas get strictly increasing stream seqs', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const update = (delta: string): void => {
    harness.pi.handlers.get('message_update')!(
      { type: 'message_update', message: {}, assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta, partial: {} } },
      harness.startCtx,
    );
  };
  update('a');
  update('b');
  const streams = parsed(socket).slice(before).filter((m) => (m.payload as { kind?: string })?.kind === 'stream');
  assert.deepEqual(streams.map((m) => (m.payload as { seq: number }).seq), [1, 2]);
});

test('thinking and text deltas share one stream seq sequence', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const update = (assistantMessageEvent: AssistantMessageEvent): void => {
    harness.pi.handlers.get('message_update')!(
      { type: 'message_update', message: {}, assistantMessageEvent },
      harness.startCtx,
    );
  };
  update(sampleAssistantEvent('thinking_start'));
  update(sampleAssistantEvent('thinking_delta'));
  // An empty delta is a shape pi-ai can produce; it must still take a seq.
  update({ type: 'thinking_delta', contentIndex: 0, delta: '', partial: {} });
  update(sampleAssistantEvent('text_delta'));
  const streams = parsed(socket)
    .slice(before)
    .filter((m) => (m.payload as { kind?: string })?.kind === 'stream')
    .map((m) => m.payload as { seq: number; text?: string; phase?: string });
  assert.deepEqual(streams, [
    { kind: 'stream', seq: 1, phase: 'thinking' },
    { kind: 'stream', seq: 2, text: 'hmm', phase: 'thinking' },
    { kind: 'stream', seq: 3, text: '', phase: 'thinking' },
    { kind: 'stream', seq: 4, text: 'hello' },
  ]);
});

// ---------------------------------------------------------------------------
// Agent state
// ---------------------------------------------------------------------------

test('agent_settled yields the terminal agent state', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({ type: 'agent_settled' }, harness.startCtx);
  // Settling is also a context-usage boundary, so the state frame is no longer
  // the last thing on the wire. Deliberate: the terminal state still comes first.
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(emitted[0]!.payload, { kind: 'agent', state: 'settled' });
  assert.deepEqual(emitted[1]!.payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
  assert.deepEqual(emitted[2]!.payload, { kind: 'settled', text: '', truncated: false });
});

test('agent_start yields the running state', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('agent_start')!({ type: 'agent_start' }, harness.startCtx);
  const last = parsed(socket).at(-1)!;
  assert.deepEqual(last.payload, { kind: 'agent', state: 'running' });
});

test('agent_end does not yield the terminal state', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('agent_start')!({ type: 'agent_start' }, harness.startCtx);
  // The bridge deliberately does not subscribe to `agent_end`; if it ever does,
  // invoking the handler must still not settle the session.
  const agentEnd = harness.pi.handlers.get('agent_end');
  if (agentEnd !== undefined) agentEnd({ type: 'agent_end' }, harness.startCtx);
  const states = parsed(socket)
    .filter((m) => (m.payload as { kind?: string })?.kind === 'agent')
    .map((m) => (m.payload as { state: string }).state);
  assert.equal(states.at(-1), 'running');
  assert.equal(states.includes('settled'), false);
});

test('the terminal agent state is re-emitted after a reconnect', () => {
  const harness = makeHarness();
  harness.start();
  const first = harness.sockets[0]!;
  first.open();
  harness.pi.handlers.get('agent_settled')!({ type: 'agent_settled' }, harness.startCtx);
  first.drop();
  harness.fireTimer();
  const second = harness.sockets[1]!;
  second.open();
  const messages = parsed(second);
  assert.equal(messages[1]!.type, 'register');
  assert.deepEqual(messages[2]!.payload, { kind: 'agent', state: 'settled' });
});

// ---------------------------------------------------------------------------
// Command dispatch
// ---------------------------------------------------------------------------

test('prompt asks pi to expand commands and templates instead of injecting text verbatim', async () => {
  const harness = makeHarness();
  // Documentation of intent, not a witness: `makeCtx` already defaults idle to
  // true, so this line cannot fail if the idle branch is absent.
  const ctx = harness.start();
  ctx.setIdle(true);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: '/implement-vetted' });
  // pi's extension API defaults `expandPromptTemplates` to false, which hands a
  // `/name` to the model as prose instead of running the command. The bridge
  // must opt in; which commands exist is pi's business, not the bridge's.
  assert.deepEqual(harness.pi.userMessages, [
    { content: '/implement-vetted', options: { expandPromptTemplates: true } },
  ]);
});

test('steer injects the text with deliverAs steer', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'steer', { text: 'hi' });
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'hi', options: { expandPromptTemplates: true, deliverAs: 'steer' } },
  ]);
});

test('followup injects the text with deliverAs followUp', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'followup', { text: 'hi' });
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'hi', options: { expandPromptTemplates: true, deliverAs: 'followUp' } },
  ]);
});

test('a prompt while the agent is streaming is queued as a steer', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'change direction' });
  // A plain `prompt` sent mid-turn is silently dropped by pi — the reply the
  // app waits on is `ok:true` either way. `steer` queues it instead.
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'change direction', options: { expandPromptTemplates: true, deliverAs: 'steer' } },
  ]);
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: true,
    queued: true,
  });
});

test('the prompt delivery mode is read per dispatch, not once at session start', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  ctx.setIdle(false);
  await sendCommand(harness.pi, socket, 'prompt', { text: 'a' });
  ctx.setIdle(true);
  await sendCommand(harness.pi, socket, 'prompt', { text: 'b' });
  // The mode follows the current turn, not a value cached at session start.
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'a', options: { expandPromptTemplates: true, deliverAs: 'steer' } },
    { content: 'b', options: { expandPromptTemplates: true } },
  ]);
});

test('an explicit steer ignores the agent idle state', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  ctx.setIdle(true);
  await sendCommand(harness.pi, socket, 'steer', { text: 's1' });
  ctx.setIdle(false);
  await sendCommand(harness.pi, socket, 'steer', { text: 's2' });
  // `steer` says what it means: idle is irrelevant, both are steers.
  assert.deepEqual(harness.pi.userMessages, [
    { content: 's1', options: { expandPromptTemplates: true, deliverAs: 'steer' } },
    { content: 's2', options: { expandPromptTemplates: true, deliverAs: 'steer' } },
  ]);
});

test('an explicit followup ignores the agent idle state', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  ctx.setIdle(false);
  await sendCommand(harness.pi, socket, 'followup', { text: 'f1' });
  ctx.setIdle(true);
  await sendCommand(harness.pi, socket, 'followup', { text: 'f2' });
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'f1', options: { expandPromptTemplates: true, deliverAs: 'followUp' } },
    { content: 'f2', options: { expandPromptTemplates: true, deliverAs: 'followUp' } },
  ]);
});

test('a prompt with images maps them to pi content parts after the text', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', {
    text: 'look',
    images: [{ data: 'AA', mimeType: 'image/jpeg' }],
  });
  // pi's `sendUserMessage` splits a content array into text + images and hands
  // them to `prompt`; the text part must come first so a caption is never lost.
  assert.deepEqual(harness.pi.userMessages, [
    {
      content: [
        { type: 'text', text: 'look' },
        { type: 'image', data: 'AA', mimeType: 'image/jpeg' },
      ],
      options: { expandPromptTemplates: true },
    },
  ]);
});

test('a non-array images value is refused as malformed images', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'x', images: 'nope' });
  // A malformed frame must fail loudly rather than send a text-only prompt the
  // app believes carried a picture.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'malformed images',
  });
  assert.deepEqual(harness.pi.userMessages, []);
});

test('an image part with a missing mimeType is refused as malformed images', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'x', images: [{ data: 'AA' }] });
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'malformed images',
  });
  assert.deepEqual(harness.pi.userMessages, []);
});

test('an image part with an empty mimeType is refused as malformed images', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', {
    text: 'x',
    images: [{ data: 'AA', mimeType: '' }],
  });
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'malformed images',
  });
  assert.deepEqual(harness.pi.userMessages, []);
});

test('an empty images array is treated as absent', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'x', images: [] });
  // The app may send an empty list; it must not make the content an array with
  // an empty image tail.
  assert.deepEqual(harness.pi.userMessages, [
    { content: 'x', options: { expandPromptTemplates: true } },
  ]);
});

test('images without text are refused as missing text before parsing images', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', {
    images: [{ data: 'AA', mimeType: 'image/jpeg' }],
  });
  // The text check comes first: an image cannot be sent alone, and the refusal
  // names the missing caption rather than the images.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'missing text',
  });
  assert.deepEqual(harness.pi.userMessages, []);
});

test('an isIdle() that throws fails the command loudly instead of crashing', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdleError(new Error('runner is not active'));
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'x' });
  // A pi lacking `isIdle` throws here. The failure must surface as a loud
  // `ok:false` on the reply the app already awaits — not an escaped rejection,
  // and not the silent drop this change exists to fix.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'runner is not active',
  });
});

test('an idle prompt reply carries no queued flag', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(true);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', { text: 'now' });
  // Only a steer chose to queue. An idle prompt is dispatched exactly as
  // before, so its reply must stay the frame an older app already understands.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: true,
  });
});

test('an explicit steer reply carries no queued flag', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'steer', { text: 's' });
  // `steer` names its mode; it is not the bridge deciding to queue a plain
  // prompt mid-turn, so it must not claim the queued signal.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-steer',
    ok: true,
  });
});

test('an explicit followup reply carries no queued flag', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'followup', { text: 'f' });
  // `followup` names its mode too — it forces `followUp` regardless of idle,
  // so, like `steer`, it must not claim the queued signal.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-followup',
    ok: true,
  });
});

test('a refused prompt reply carries no queued flag', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'prompt', {});
  // A refusal is not a queue: `ok:false` must stand alone, with no queued hint
  // the app could render as success.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-prompt',
    ok: false,
    error: 'missing text',
  });
});

test('abort aborts the active operation and acknowledges dispatch', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'abort');
  assert.equal(ctx.aborts(), 1);
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-abort',
    ok: true,
  });
});

test('setModel resolves the reference through the registry before calling pi', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  // The resolved registry OBJECT, not the `{provider, id}` reference: pi's
  // setModel needs the full Model, and passing the reference would be a
  // type-lie pi cannot use.
  assert.deepEqual(harness.pi.models, [
    { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  ]);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
});

test('setModel reports a rejected model as a failed command-result', async () => {
  const harness = makeHarness();
  harness.pi.modelAccepted = false;
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // The wrapper's `false` path (a stale auth snapshot), distinct from the
  // unknown-id `'model not found'` and the no-registry `'models unavailable'`.
  assert.equal(result.error, 'model not accepted');
});

test('setModel refuses an unknown model without calling pi', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { provider: 'test-provider', id: 'nope' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'model not found');
  assert.deepEqual(harness.pi.models, [], 'pi.setModel must not be called for an unknown model');
});

test('setModel without a provider or id is refused', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { id: 'test-model' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'missing model');
  assert.deepEqual(harness.pi.models, []);
});

test('setModel without a registry is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.removeRegistry();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { provider: 'test-provider', id: 'test-model' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'models unavailable');
  assert.deepEqual(harness.pi.models, []);
});

test('setModel is refused mid-turn, before calling pi', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', { provider: 'test-provider', id: 'test-model' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'cannot switch the model while pi is working');
  // pi's own AgentSession.setModel has no streaming guard; the bridge refuses
  // before the switch so the session cannot end up on a mixed-model turn.
  assert.deepEqual(harness.pi.models, [], 'pi.setModel must not be called mid-turn');
});

test('a throwing pi.setModel surfaces the thrown message, not the accepted boolean', async () => {
  const harness = makeHarness();
  harness.pi.modelError = new Error('No API key for test-provider/test-model');
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // A stale auth snapshot makes pi's inner setModel THROW; the message must
  // survive rather than be replaced by the wrapper's `'model not accepted'`.
  assert.equal(result.error, 'No API key for test-provider/test-model');
});

test('an accepted same-model switch still re-reports usage exactly once', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  // `_emitModelSelect` early-returns for an equal model, so the direct
  // `sendUsageEvent` is the only frame and must not be dropped.
  // The exact count pins StubPi's behaviour (its `setModel` never emits
  // `model_select`), not a wire guarantee: real pi also emits the event, which
  // the bridge documents as a harmless idempotent duplicate. If the stub grows
  // faithful, relax the count to >= 1 — do not "fix" the bridge.
  const usage = parsed(socket)
    .slice(before)
    .filter((message) => (message.payload as { kind?: string } | undefined)?.kind === 'usage');
  assert.equal(usage.length, 1);
});

test('setThinkingLevel dispatches the level', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setThinkingLevel', { level: 'high' });
  assert.deepEqual(harness.pi.thinkingLevels, ['high']);
});

test('compact requests compaction', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'compact');
  assert.equal(ctx.compacts(), 1);
});

test('fetchHistory replies with a history message', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'fetchHistory');
  const history = parsed(socket).find((m) => m.type === 'history')!;
  assert.deepEqual(history.entries, [{ type: 'message', id: 'e1' }]);
  assert.equal(history.truncated, false);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
});

test('a history-request replays history and then the context usage', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  const after = parsed(socket).slice(-2);
  assert.equal(after[0]!.type, 'history');
  // A phone that attaches mid-session must see a number without waiting for a
  // turn, and the hub only relays to subscribers — which is why this rides the
  // reply rather than the register frame.
  assert.deepEqual(after[1], {
    protocolVersion: PROTOCOL_VERSION,
    type: 'event',
    payload: {
      kind: 'usage',
      tokens: 23400,
      contextWindow: 128000,
      thinkingLevel: 'medium',
      model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
    },
  });
});

test('an unknown token count travels as null', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setUsage({ tokens: null, contextWindow: 128000 });
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: null,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('agent_settled reports the terminal state and then the usage', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(
    emitted.map((m) => (m.payload as { kind?: string }).kind),
    ['agent', 'usage', 'settled'],
  );
});

test('a compaction reports unknown tokens', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  ctx.setUsage({ tokens: null, contextWindow: 128000 });
  harness.pi.handlers.get('session_compact')!({}, ctx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual((emitted.at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: null,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('a context without a thinking level omits the field', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete ctx.thinkingLevel;
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  // The key must be absent, not `null`: an older pi exposes no level and the
  // field is optional.
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('a context without a model omits the field', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete ctx.model;
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  // The key must be absent, not `null`: an older pi exposes no model and the
  // field is optional.
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
  });
});

test('a malformed model is omitted, never sent half-formed', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // `name` missing: the projection must drop the whole entry rather than emit a
  // `ModelSummary` the protocol validator would reject.
  ctx.model = { id: 'test-model', provider: 'test-provider' } as unknown as BridgeModel;
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual((parsed(socket).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
  });
});

test('a model_select re-reports usage', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  ctx.model = { id: 'm2', provider: 'test-provider', name: 'Second Model' };
  harness.pi.handlers.get('model_select')!(
    { model: ctx.model, previousModel: undefined, source: 'select' },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'medium',
    model: { provider: 'test-provider', id: 'm2', name: 'Second Model' },
  });
});

test('a thinking level change re-reports usage', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  ctx.thinkingLevel = 'low';
  harness.pi.handlers.get('thinking_level_select')!(
    { level: 'low', previousLevel: 'medium' },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'low',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('the reported thinking level is read live, not cached', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  ctx.thinkingLevel = 'high';
  const before = socket.sent.length;
  harness.pi.handlers.get('thinking_level_select')!(
    { level: 'high', previousLevel: 'low' },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'usage',
    tokens: 23400,
    contextWindow: 128000,
    thinkingLevel: 'high',
    model: { provider: 'test-provider', id: 'test-model', name: 'Test Model' },
  });
});

test('a failed compaction reaches the transcript as an error notice', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!(
    { reason: 'manual', errorMessage: 'Compaction failed: no model', aborted: false },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'status',
    event: 'error',
    message: 'Compaction failed: no model',
  });
});

test('an overflow compaction failure also reaches the transcript', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!(
    {
      reason: 'overflow',
      errorMessage: 'Context overflow recovery failed: too large',
      aborted: false,
    },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'status',
    event: 'error',
    message: 'Context overflow recovery failed: too large',
  });
});

test('an aborted compaction clears the announcement without an error notice', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!({ reason: 'manual', aborted: true }, ctx);
  // The announcement must still be cleared — an aborted compaction is over just
  // like a failed one — but nothing is shown, because nothing went wrong.
  assert.deepEqual(parsed(socket).slice(before).map((m) => (m as { payload: unknown }).payload), [
    { kind: 'status', event: 'compacting', active: false },
  ]);
});

test('a compaction start announces itself to the app', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_before_compact')!(
    { type: 'session_before_compact', reason: 'manual', willRetry: false },
    ctx,
  );
  assert.deepEqual((parsed(socket).slice(before).at(-1) as { payload: unknown }).payload, {
    kind: 'status',
    event: 'compacting',
    active: true,
  });
});

test('the compaction start handler neither cancels nor customises the compaction', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  harness.sockets[0]!.open();
  // pi awaits this handler and reads the result: a truthy `cancel` aborts the
  // compaction and a `compaction` replaces the summary. Returning undefined is
  // what keeps the bridge from silently changing what compaction does.
  const result = harness.pi.handlers.get('session_before_compact')!(
    { type: 'session_before_compact', reason: 'threshold', willRetry: true },
    ctx,
  );
  assert.equal(result, undefined);
});

test('a completed compaction clears the announcement', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact')!({ type: 'session_compact', reason: 'manual' }, ctx);
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .map((m) => (m as { payload: { kind: string; event?: string } }).payload)
      .filter((p) => p.kind === 'status'),
    [{ kind: 'status', event: 'compacting', active: false }],
  );
});

test('a failed compaction clears the announcement before the error notice', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('session_compact_failed')!(
    { reason: 'overflow', errorMessage: 'Context overflow recovery failed', aborted: false },
    ctx,
  );
  // Order matters: the indicator is cleared first, so the app cannot end up
  // showing "Compacting…" and a failure notice at the same time.
  assert.deepEqual(parsed(socket).slice(before).map((m) => (m as { payload: unknown }).payload), [
    { kind: 'status', event: 'compacting', active: false },
    { kind: 'status', event: 'error', message: 'Context overflow recovery failed' },
  ]);
});

test('an accepted model switch reports the new window', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setUsage({ tokens: 100, contextWindow: 200000 });
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    ['usage'],
  );
});

test('a refused model switch reports nothing about usage', async () => {
  const harness = makeHarness();
  harness.pi.modelAccepted = false;
  const ctx = harness.start();
  ctx.setUsage({ tokens: 100, contextWindow: 200000 });
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  await sendCommand(harness.pi, socket, 'setModel', {
    provider: 'test-provider',
    id: 'test-model',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    [],
  );
});

test('a pi without getContextUsage emits no usage frame', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete ctx.getContextUsage;
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    [],
  );
  // The history reply itself must still arrive: a missing usage reading is not
  // allowed to take the transcript down with it.
  assert.ok(parsed(socket).some((m) => m.type === 'history'));
});

test('an undefined usage reading emits no usage frame', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setUsage(undefined);
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.deepEqual(
    parsed(socket)
      .slice(before)
      .filter((m) => m.type === 'event')
      .map((m) => (m.payload as { kind?: string }).kind),
    [],
  );
});

test('a throwing getContextUsage does not escape and costs only the reading', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.getContextUsage = () => {
    throw new Error('usage exploded');
  };
  const socket = harness.sockets[0]!;
  socket.open();
  assert.doesNotThrow(() => {
    socket.message({
      protocolVersion: PROTOCOL_VERSION,
      type: 'history-request',
      sessionId: 'sess-1',
    });
  });
  assert.deepEqual(harness.writes, []);
  assert.ok(parsed(socket).some((m) => m.type === 'history'));
});

test('stream deltas never sample the context', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const update = (): void => {
    harness.pi.handlers.get('message_update')!(
      {
        type: 'message_update',
        message: {},
        assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: 'x', partial: {} },
      },
      ctx,
    );
  };
  for (let index = 0; index < 20; index += 1) update();
  // Reading it walks the whole session projection, so it is a boundary cost and
  // must never land on the delta path.
  assert.equal(ctx.usageCalls(), 0);
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  assert.equal(ctx.usageCalls(), 1);
});

test('a history-request from the hub is answered with a history message', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  const history = parsed(socket).find((m) => m.type === 'history')!;
  assert.equal(history.sessionId, 'sess-1');
  assert.deepEqual(history.entries, [{ type: 'message', id: 'e1' }]);
});

test('history-request projects the active branch, not the whole file', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // a1 is on an abandoned branch; only b1/b2 are on the active one.
  ctx.setEntries([
    { type: 'message', id: 'a1', message: { role: 'user', content: 'abandoned' } },
    { type: 'message', id: 'b1', message: { role: 'user', content: 'kept' } },
    { type: 'message', id: 'b2', message: { role: 'assistant', content: 'reply' } },
  ]);
  ctx.setBranchEntries([
    { type: 'message', id: 'b1', message: { role: 'user', content: 'kept' } },
    { type: 'message', id: 'b2', message: { role: 'assistant', content: 'reply' } },
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
  });
  const history = parsed(socket).find((m) => m.type === 'history');
  assert.ok(history, 'a history frame must be sent');
  const entries = history.entries as Array<{ id: string }>;
  assert.deepEqual(entries.map((entry) => entry.id), ['b1', 'b2']);
});

test('a throwing getEntries on the history-request path does not escape and writes nothing', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  ctx.sessionManager.getEntries = () => {
    throw new Error('entries exploded');
  };
  assert.doesNotThrow(() => {
    socket.message({
      protocolVersion: PROTOCOL_VERSION,
      type: 'history-request',
      sessionId: 'sess-1',
    });
  });
  assert.deepEqual(harness.writes, []);
});

test('setSessionName sets the session name', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setSessionName', { name: 'Phone chat' });
  assert.deepEqual(harness.pi.sessionNames, ['Phone chat']);
});

test("listCommands answers with pi's commands, dropping source and absent descriptions", async () => {
  const harness = makeHarness();
  harness.pi.commands = [
    {
      name: 'review',
      description: 'Review the working tree',
      source: 'extension',
      sourceInfo: { path: '/ext/review.md' },
    },
    { name: 'implement-vetted', source: 'prompt', sourceInfo: { path: '/prompts/implement-vetted.md' } },
  ];
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  // `source`/`sourceInfo` must not travel, and an absent description must not
  // become an empty string: the app needs a label and an optional subtitle only.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-listCommands',
    ok: true,
    commands: [
      { name: 'review', description: 'Review the working tree' },
      { name: 'implement-vetted' },
    ],
  });
});

test('a listCommands reply carries no queued flag', async () => {
  const harness = makeHarness();
  harness.pi.commands = [{ name: 'review' }];
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  // `sendCommandResult` is a shared path; only the prompt branch may set the
  // queued key, so a command result must stay exactly its own shape.
  assert.deepEqual(parsed(socket).at(-1), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id: 'c-listCommands',
    ok: true,
    commands: [{ name: 'review' }],
  });
});

test('listCommands reports failure when pi has no getCommands method', async () => {
  const harness = makeHarness();
  // Older pi: the method is absent, so the bridge's optional call must
  // short-circuit. Deleting it is what exercises `?.`; a present method that
  // returns `undefined` takes the `raw === undefined` guard instead.
  (harness.pi as { getCommands?: unknown }).getCommands = undefined;
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as {
    type: string;
    ok: boolean;
    error?: string;
    commands?: unknown;
  };
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
  // The specific reason matters: a plain allowlist refusal would also be
  // `ok:false`, so this pins the bridge's own no-list branch.
  assert.equal(result.error, 'commands unavailable');
  assert.equal(result.commands, undefined);
});

test('listCommands reports failure when getCommands returns undefined', async () => {
  const harness = makeHarness();
  harness.pi.commandsAvailable = false;
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as {
    type: string;
    ok: boolean;
    error?: string;
    commands?: unknown;
  };
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
  assert.equal(result.error, 'commands unavailable');
  assert.equal(result.commands, undefined);
});

test('listCommands preserves duplicate names in pi order', async () => {
  const harness = makeHarness();
  harness.pi.commands = [
    { name: 'review', description: 'first' },
    { name: 'other' },
    { name: 'review', description: 'second' },
    // Malformed entries are skipped by the `continue` path, never crash the
    // loop and never reach the wire.
    null,
    42,
    'oops',
  ] as unknown as typeof harness.pi.commands;
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as {
    commands: Array<{ name: string; description?: string }>;
  };
  // Duplicates are preserved and ordered: a future dedupe must be deliberate.
  assert.deepEqual(result.commands, [
    { name: 'review', description: 'first' },
    { name: 'other' },
    { name: 'review', description: 'second' },
  ]);
});

test('listModels returns the available models projected to provider, id and name', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setAvailable([
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
    { provider: 'openai', id: 'gpt-5', name: 'GPT-5' },
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; models?: unknown };
  assert.equal(result.ok, true, `listModels was refused: ${String((result as { error?: string }).error)}`);
  assert.deepEqual(result.models, [
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
    { provider: 'openai', id: 'gpt-5', name: 'GPT-5' },
  ]);
});

test('listModels drops an entry missing provider, id or name', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setAvailable([
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
    { provider: 'anthropic', name: 'no id' },
    { id: 'no-provider', name: 'N' },
    { provider: 'p', id: 'm' },
    null,
    42,
    'oops',
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { models?: unknown };
  assert.deepEqual(result.models, [
    { provider: 'anthropic', id: 'claude-sonnet-4', name: 'Claude Sonnet 4' },
  ]);
});

test('listModels never lets a credential or extra model field reach the wire', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setAvailable([
    {
      provider: 'p',
      id: 'm',
      name: 'M',
      headers: { authorization: 'secret' },
      baseUrl: 'http://x',
      compat: { something: true },
      cost: { input: 1 },
    },
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { models?: unknown };
  // Deep equality, not a field check: an extra key would fail this too.
  assert.deepEqual(result.models, [{ provider: 'p', id: 'm', name: 'M' }]);
});

test('an older pi without a registry is refused, not reported as empty', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.removeRegistry();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string; models?: unknown };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'models unavailable');
  // `[]` would be a lie: the app must not show an empty picker as a real answer.
  assert.equal(result.models, undefined);
});

test('a registry whose getAvailable is not an array is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.modelRegistry = {
    getAvailable: () => 'nope' as unknown as unknown[],
    find: () => undefined,
  };
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'models unavailable');
});

test('a registry whose getAvailable throws reports the thrown message', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.modelRegistry = {
    getAvailable: () => {
      throw new Error('registry exploded');
    },
    find: () => undefined,
  };
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listModels');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // The throw must reach `dispatch`'s catch and surface verbatim, not be
  // swallowed into a generic refusal.
  assert.equal(result.error, 'registry exploded');
});

test('the bridge and hub command allowlists are identical', () => {
  // Drift is silent and costly: the hub-allows/bridge-refuses direction yields
  // `command not allowed`, the other `unknown command`, and the only other net
  // is the real-pi capstone, which pays a pi spawn. This is test-only coupling.
  assert.deepEqual(
    [...BRIDGE_COMMAND_ALLOWLIST].sort(),
    [...HUB_COMMAND_ALLOWLIST].sort(),
  );
});

test('every allowlisted command is actually dispatched', async () => {
  // The allowlist is a promise to the app, and nothing checked that the
  // dispatcher keeps it: a name on the list with no case falls through to the
  // `default` and the app is told `command not allowed` for a command the list
  // says it may send. `fetchHistory` is handled in `dispatch`, *before*
  // `dispatchCommand`, which is exactly how a reader of the switch alone
  // concludes it is unimplemented — it is not.
  // The session-control names must stay covered: iterating the allowlist
  // silently shrinks if one is dropped, so pin them here.
  for (const name of ['listTree', 'sessionNew', 'sessionTree', 'sessionFork']) {
    assert.ok(BRIDGE_COMMAND_ALLOWLIST.has(name), `${name} is missing from the allowlist`);
  }
  for (const name of BRIDGE_COMMAND_ALLOWLIST) {
    const harness = makeHarness();
    harness.start();
    const socket = harness.sockets[0]!;
    socket.open();
    // Deliberately empty args: every real case answers with its own specific
    // complaint (`missing text`, `missing model`, …) and only a missing case
    // answers with the generic refusal. A case's own error is proof it exists.
    await sendCommand(harness.pi, socket, name);
    const result = parsed(socket).find((m) => m.type === 'command-result') as
      | { ok: boolean; error?: string }
      | undefined;
    // Presence first: `result?.error` is `undefined` when no reply arrived at
    // all, which would satisfy the assertion below and turn this guard into a
    // vacuous pass — the exact failure it exists to catch.
    assert.ok(result, `${name} produced no command-result`);
    assert.notEqual(
      result.error,
      COMMAND_NOT_ALLOWED,
      `${name} is allowlisted but the dispatcher has no case for it`,
    );
  }
});

// ---------------------------------------------------------------------------
// Refusals
// ---------------------------------------------------------------------------

test('exec is refused, not ignored', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'exec', { command: 'rm', args: ['-rf', '/'] });
  const result = parsed(socket).at(-1) as { type: string; ok: boolean };
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
});

test('shutdown is refused without shutting down', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'shutdown');
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('setActiveTools is refused', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setActiveTools', { tools: ['bash'] });
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('an unknown command is refused', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'definitelyNotACommand');
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('a command arriving after the session turns inert is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start('tui');
  const socket = harness.sockets[0]!;
  socket.open();
  // A future socket path must not be able to dispatch once the mode is inert;
  // the guard is re-checked at dispatch, not only at session_start.
  ctx.mode = 'json';
  await sendCommand(harness.pi, socket, 'prompt', { text: 'hi' });
  assert.deepEqual(harness.pi.userMessages, []);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('a command whose sessionId is not this session is refused', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'c-other',
    sessionId: 'other-session',
    name: 'abort',
  });
  await tick();
  assert.equal(ctx.aborts(), 0);
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, false);
});

test('refusal is not defeatable by casing or whitespace', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  for (const name of ['Prompt', 'PROMPT', ' prompt', 'prompt ', 'exec ', 'Shutdown', 'setactivetools']) {
    await sendCommand(harness.pi, socket, name, { text: 'hi' });
    const result = parsed(socket).at(-1) as { ok: boolean };
    assert.equal(result.ok, false, `${name} was not refused`);
  }
  assert.deepEqual(harness.pi.userMessages, []);
});

// ---------------------------------------------------------------------------
// Reconnect backoff
// ---------------------------------------------------------------------------

test('backoff never exceeds its cap across many attempts', () => {
  for (let attempt = 0; attempt <= 1000; attempt += 1) {
    const delay = computeBackoff(attempt, { rng: () => 1 });
    assert.ok(delay <= 30_000, `attempt ${attempt} yielded ${delay}`);
  }
});

test('backoff jitters between calls at the same attempt', () => {
  const low = computeBackoff(4, { rng: () => 0.1 });
  const high = computeBackoff(4, { rng: () => 0.9 });
  assert.notEqual(low, high);
});

test('a 4003 capability close does not schedule a reconnect', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.drop(4003);
  assert.equal(harness.timers.length, 0, 'a bridge capability bug must not retry forever');
});

test('a 4008 rate-limit close reconnects after a fixed longer delay', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.drop(4008);
  assert.equal(harness.timers.length, 1);
  assert.equal(harness.timers[0]!.ms, RATE_LIMITED_RECONNECT_MS);
  assert.ok(RATE_LIMITED_RECONNECT_MS > 500, 'the rate-limit wait exceeds the first backoff step');
  // Fired once, the reconnect is dialled and the next 4008 waits the same
  // fixed span rather than a jittered backoff step.
  harness.fireTimer();
  const second = harness.sockets[1]!;
  second.open();
  second.drop(4008);
  assert.equal(harness.timers[1]!.ms, RATE_LIMITED_RECONNECT_MS);
});

test('a dropped socket schedules a reconnect through the injected clock', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  assert.equal(harness.timers.length, 0);
  socket.drop();
  assert.equal(harness.timers.length, 1);
  assert.ok(harness.timers[0]!.ms <= 30_000);
});

test('reconnect resends hello, register and the current agent state', () => {
  const harness = makeHarness();
  harness.start();
  const first = harness.sockets[0]!;
  first.open();
  first.drop();
  harness.fireTimer();
  const second = harness.sockets[1]!;
  second.open();
  const types = parsed(second).map((m) => m.type);
  assert.deepEqual(types.slice(0, 2), ['hello', 'register']);
  assert.deepEqual(parsed(second)[2]!.payload, { kind: 'agent', state: 'idle' });
});

// ---------------------------------------------------------------------------
// Mode guard
// ---------------------------------------------------------------------------

test('tui and rpc are active modes', () => {
  assert.equal(isActiveMode('tui'), true);
  assert.equal(isActiveMode('rpc'), true);
});

test('json and print are inert modes', () => {
  assert.equal(isActiveMode('json'), false);
  assert.equal(isActiveMode('print'), false);
});

test('an inert mode opens no socket', () => {
  const harness = makeHarness();
  harness.start('print');
  assert.equal(harness.sockets.length, 0);
});

test('an inert mode writes nothing', () => {
  const harness = makeHarness();
  harness.start('json');
  assert.deepEqual(harness.writes, []);
});

// ---------------------------------------------------------------------------
// Silence
// ---------------------------------------------------------------------------

test('nothing is written without PI_DROID_DEBUG=1', () => {
  const harness = makeHarness({ resolveEndpoint: () => null });
  harness.start();
  assert.deepEqual(harness.writes, []);
});

test('debug output goes to stderr when PI_DROID_DEBUG=1', () => {
  const harness = makeHarness({ env: { PI_DROID_DEBUG: '1' }, resolveEndpoint: () => null });
  harness.start();
  assert.ok(harness.writes.length > 0);
  assert.ok(harness.writes.every((write) => write.stream === 'stderr'));
});

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

test('the factory opens no socket', () => {
  const harness = makeHarness();
  assert.equal(harness.sockets.length, 0);
});

test('the socket opens in session_start', () => {
  const harness = makeHarness();
  harness.start();
  assert.equal(harness.sockets.length, 1);
});

test('register carries the session identity', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.sessionId, 'sess-1');
  assert.equal(register.sessionFile, '/sessions/sess-1.jsonl');
  assert.equal(register.cwd, '/work');
  assert.equal(register.model, 'test-model');
  assert.equal(register.thinkingLevel, 'medium');
  assert.equal(register.mode, 'tui');
  assert.equal(register.pid, process.pid);
});

// ---------------------------------------------------------------------------
// Session labels
// ---------------------------------------------------------------------------

test('register carries the last user prompt as the label', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    { type: 'message', message: { role: 'assistant', content: 'reply' } },
    { type: 'message', message: { role: 'user', content: 'first' } },
    { type: 'message', message: { role: 'user', content: 'last prompt' } },
  ];
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, 'last prompt');
});

test('an explicit session name beats the last user prompt', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    { type: 'message', message: { role: 'user', content: 'last prompt' } },
  ];
  harness.pi.setSessionName('explicit');
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, 'explicit');
});

test('a label is sanitized', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    { type: 'message', message: { role: 'user', content: '  hello\n\n\tworld  ' } },
  ];
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, 'hello world');
});

test('a label truncates over code points, never splitting an emoji', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    { type: 'message', message: { role: 'user', content: '😀'.repeat(81) } },
  ];
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, '😀'.repeat(80));
  assert.equal(Array.from(register.name as string).length, 80);
});

test('an image-only user message puts no name on the wire', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    {
      type: 'message',
      message: { role: 'user', content: [{ type: 'image', data: 'x', mimeType: 'image/png' }] },
    },
  ];
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal('name' in register, false);
});

test('an empty session name falls back to the last prompt, never name: ""', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    { type: 'message', message: { role: 'user', content: 'last prompt' } },
  ];
  harness.pi.setSessionName('');
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, 'last prompt');
});

test('a mixed text+image prompt contributes only its text', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.sessionManager.getEntries = () => [
    {
      type: 'message',
      message: {
        role: 'user',
        content: [
          { type: 'image', data: 'x', mimeType: 'image/png' },
          { type: 'text', text: 'look  at this' },
        ],
      },
    },
  ];
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.equal(register.name, 'look at this');
});

test('a throwing getSessionName still sends the register frame without a name', () => {
  const harness = makeHarness();
  harness.start();
  harness.pi.getSessionName = () => {
    throw new Error('boom');
  };
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.ok(register);
  assert.equal('name' in register, false);
});

test('a new user prompt re-registers with the new label', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  assert.equal(parsed(socket).filter((m) => m.type === 'register').length, 1);
  harness.pi.handlers.get('message_end')!(
    { type: 'message_end', message: { role: 'user', content: 'new topic' } },
    harness.startCtx,
  );
  const registers = parsed(socket).filter((m) => m.type === 'register');
  assert.equal(registers.length, 2);
  assert.equal(registers[1]!.name, 'new topic');
});

test('a repeated prompt with the same text does not re-register', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  const event = { type: 'message_end', message: { role: 'user', content: 'same' } };
  handler(event, harness.startCtx);
  handler(event, harness.startCtx);
  assert.equal(parsed(socket).filter((m) => m.type === 'register').length, 2);
});

test('an image-only prompt does not re-register', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('message_end')!(
    {
      type: 'message_end',
      message: { role: 'user', content: [{ type: 'image', data: 'x', mimeType: 'image/png' }] },
    },
    harness.startCtx,
  );
  assert.equal(parsed(socket).filter((m) => m.type === 'register').length, 1);
});

test('a non-user message_end does not re-register', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('message_end')!(
    { type: 'message_end', message: { role: 'assistant', content: 'reply' } },
    harness.startCtx,
  );
  assert.equal(parsed(socket).filter((m) => m.type === 'register').length, 1);
});

test('setSessionName re-registers with the new name', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'setSessionName', { name: 'Phone chat' });
  const registers = parsed(socket).filter((m) => m.type === 'register');
  assert.equal(registers.length, 2);
  assert.equal(registers[1]!.name, 'Phone chat');
});

test('a throwing getEntries during register still sends the register frame', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  (harness.pi as { getSessionName?: unknown }).getSessionName = undefined;
  ctx.sessionManager.getEntries = () => {
    throw new Error('entries exploded');
  };
  const socket = harness.sockets[0]!;
  socket.open();
  const register = parsed(socket).find((m) => m.type === 'register')!;
  assert.ok(register);
  assert.equal('name' in register, false);
});

test('a session_info_changed event from a TUI rename re-registers', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.setSessionName('tui rename');
  harness.pi.handlers.get('session_info_changed')!(
    { type: 'session_info_changed', name: 'tui rename' },
    harness.startCtx,
  );
  const registers = parsed(socket).filter((m) => m.type === 'register');
  assert.equal(registers.length, 2);
  assert.equal(registers[1]!.name, 'tui rename');
});

test('session_shutdown closes the socket', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  assert.equal(socket.closeCalls.length, 1);
});

test('session_shutdown is idempotent', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  assert.equal(socket.closeCalls.length, 1);
});

test('a new session_start closes the previous socket and re-registers', () => {
  const harness = makeHarness();
  harness.start();
  const first = harness.sockets[0]!;
  first.open();
  harness.start('tui');
  const second = harness.sockets[1]!;
  second.open();
  assert.equal(first.closeCalls.length, 1);
  assert.equal(second.sent.filter((text) => JSON.parse(text).type === 'register').length, 1);
});

test('the retained context follows a session switch', async () => {
  const harness = makeHarness();
  harness.start();
  harness.sockets[0]!.open();
  const secondCtx = harness.start();
  const secondSocket = harness.sockets[1]!;
  secondSocket.open();
  await sendCommand(harness.pi, secondSocket, 'abort');
  assert.equal(secondCtx.aborts(), 1);
});

test('install registers the internal session command', () => {
  const harness = makeHarness();
  // The bridge can only drive a session action through a real command context,
  // and a command context is reachable only from a registered command. One
  // registration, once per install.
  assert.deepEqual(
    harness.pi.registeredCommands.map((command) => command.name),
    [SESSION_COMMAND_NAME],
  );
});

test('a replacement session_start registers the id it replaced', () => {
  for (const reason of ['new', 'fork', 'resume']) {
    // Real replacement: pi re-runs the extension factory, so the successor's
    // `session_start` lands on a NEW bridge instance that knows the predecessor
    // only through the module-level value. Modelling that needs a second
    // install, not a re-fire on the same instance.
    const real = makeHarness();
    real.start('tui', 'sess-1', 'startup');
    real.sockets[0]!.open();
    real.reinstall();
    real.start('tui', 'sess-2', reason);
    const realSecond = real.sockets[1]!;
    realSecond.open();
    const realRegister = parsed(realSecond).find((m) => m.type === 'register')!;
    assert.equal(
      realRegister.replaces,
      'sess-1',
      `${reason} did not carry replaces across a real replacement`,
    );

    // Same-instance re-fire, which still pins the module-state comparison.
    const inPlace = makeHarness();
    inPlace.start('tui', 'sess-1', 'startup');
    inPlace.sockets[0]!.open();
    inPlace.start('tui', 'sess-2', reason);
    const second = inPlace.sockets[1]!;
    second.open();
    const register = parsed(second).find((m) => m.type === 'register')!;
    assert.equal(register.replaces, 'sess-1', `${reason} did not carry replaces`);
  }
});

test('resetSessionLinkageForTests clears the module-level predecessor', () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  resetSessionLinkageForTests();
  harness.start('tui', 'sess-2', 'new');
  const second = harness.sockets[1]!;
  second.open();
  const register = parsed(second).find((m) => m.type === 'register')!;
  // Without the clear, the module still names sess-1 and the successor would be
  // linked to a session a previous test registered, not this one's.
  assert.equal(register.replaces, undefined, 'the reset must clear the recorded predecessor');
});

test('a non-replacement session_start carries no replaces', () => {
  for (const reason of ['startup', 'reload']) {
    const harness = makeHarness();
    harness.start('tui', 'sess-1', 'startup');
    harness.sockets[0]!.open();
    harness.start('tui', 'sess-2', reason);
    const second = harness.sockets[1]!;
    second.open();
    const register = parsed(second).find((m) => m.type === 'register')!;
    assert.equal(register.replaces, undefined, `${reason} carried replaces`);
  }
});

test('a resume that reloads the same session id carries no replaces', () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  // `/resume` can reload the very id already registered; naming it as replaced
  // would make the app follow a successor that does not exist.
  harness.start('tui', 'sess-1', 'resume');
  const second = harness.sockets[1]!;
  second.open();
  const register = parsed(second).find((m) => m.type === 'register')!;
  assert.equal(register.replaces, undefined);
});

test('replaces survives a register that could not be sent and is cleared only after one that was', () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  harness.start('tui', 'sess-2', 'new');
  // sockets[1] is deliberately left closed, and a label refresh is the one
  // closed-socket path that calls `sendRegister`. It must not consume the
  // replacement: nothing reached the hub, so the app never saw the linkage.
  harness.pi.setSessionName('renamed while closed');
  harness.pi.handlers.get('session_info_changed')!(
    { type: 'session_info_changed' },
    harness.startCtx,
  );
  const second = harness.sockets[1]!;
  second.open();
  const registers = parsed(second).filter((m) => m.type === 'register');
  assert.equal(registers.length, 1);
  assert.equal(registers[0]!.replaces, 'sess-1');
  // A second rename now reaches the open socket, so the flag is consumed and the
  // next register omits it — it must not link a third, later register.
  harness.pi.setSessionName('renamed while open');
  harness.pi.handlers.get('session_info_changed')!(
    { type: 'session_info_changed' },
    harness.startCtx,
  );
  const after = parsed(second).filter((m) => m.type === 'register');
  assert.equal(after.length, 2);
  assert.equal(after[1]!.replaces, undefined);
});

test('sessionNew acknowledges and triggers the registered command', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionNew');
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
  // The only route to a command context is a real command invocation, so the
  // bridge triggers its own registered command rather than calling pi directly.
  assert.deepEqual(
    harness.pi.userMessages.map((message) => message.content),
    [`/${SESSION_COMMAND_NAME} new`],
  );
});

test('the registered handler for new calls newSession exactly once and returns', async () => {
  const harness = makeHarness();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  await handler('new', cmdCtx);
  // The stub throws on a second call, modelling pi's `assertActive`: a handler
  // that touched the context again after `newSession` would blow up here.
  assert.deepEqual(cmdCtx.calls, ['newSession']);
});

test('a cancelled newSession emits an error status instead of a silent ack', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  cmdCtx.setCancel(true);
  await handler('new', cmdCtx);
  // pi resolves `{cancelled:true}` when a `session_before_switch` handler
  // cancels. Without this notice the app would wait on a replacement that will
  // never come.
  const status = parsed(socket).find(
    (message) =>
      message.type === 'event' && (message.payload as { kind?: string }).kind === 'status',
  );
  assert.ok(status, 'a cancelled replacement emitted no status');
  assert.equal((status.payload as { event?: string }).event, 'error');
});

test('a navigateTree failure emits an error status', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  cmdCtx.setThrow(new Error('cannot navigate'));
  await handler('tree t9', cmdCtx);
  // `navigateTree` throws on a streaming/compacting session or an unknown id.
  // The throw must become a notice, never an unhandled rejection inside pi.
  const status = parsed(socket).find(
    (message) =>
      message.type === 'event' && (message.payload as { kind?: string }).kind === 'status',
  );
  assert.ok(status, 'a throwing tree navigation emitted no status');
  assert.equal((status.payload as { event?: string }).event, 'error');
  assert.match((status.payload as { message?: string }).message ?? '', /cannot navigate/);
});

test('an unknown session action emits an error status instead of a silent ack', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  // `dispatch` has already acked `ok:true`; a mistyped action must not fall off
  // the end of the handler silently.
  await handler('bogus t1', new StubCommandCtx());
  const status = parsed(socket).find(
    (message) =>
      message.type === 'event' && (message.payload as { kind?: string }).kind === 'status',
  );
  assert.ok(status, 'an unknown action emitted no status');
  assert.equal((status.payload as { event?: string }).event, 'error');
  assert.equal(
    (status.payload as { message?: string }).message,
    'unknown session action: bogus',
  );
  // An empty action names itself too, rather than printing nothing.
  await handler('', new StubCommandCtx());
  const last = parsed(socket).at(-1) as { payload?: { message?: string } };
  assert.equal(last.payload?.message, 'unknown session action: (empty)');
});

test('sessionTree refuses while pi is working', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setIdle(false);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionTree', { entryId: 't1' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  // The specific reason, not the generic allowlist refusal: `navigateTree`
  // throws mid-stream, so the bridge refuses before triggering the command.
  assert.equal(result.error, 'cannot navigate the tree while pi is working');
  assert.deepEqual(harness.pi.userMessages, []);
});

test('a session_tree event emits a leaf event with the new leaf', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const handler = harness.pi.handlers.get('session_tree');
  assert.ok(handler, 'the bridge must subscribe to pi\'s session_tree event');
  handler!({ type: 'session_tree', newLeafId: 'e9', oldLeafId: 'e1' }, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(emitted.at(-1)?.payload, { kind: 'leaf', leafId: 'e9' });
});

test('a session_tree to the root emits leafId null', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const handler = harness.pi.handlers.get('session_tree');
  assert.ok(handler, 'the bridge must subscribe to pi\'s session_tree event');
  handler!({ type: 'session_tree', newLeafId: null, oldLeafId: 'e1' }, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(emitted.at(-1)?.payload, { kind: 'leaf', leafId: null });
});

test('sessionTree refuses an entry id pi does not know', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // The id was listed earlier but the entry is gone now: pi's navigateTree
  // would throw after the ack, so the refusal must happen at dispatch.
  ctx.setEntries([{ type: 'message', id: 'e1', message: { role: 'user', content: 'hi' } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionTree', { entryId: 'gone' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'unknown entry');
  // Refused before the command is ever triggered.
  assert.deepEqual(harness.pi.userMessages, []);
});

test('sessionFork rejects a non-user entry', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // Forking with the default `before` position requires a user message entry;
  // an assistant entry is not a valid fork target.
  ctx.setEntries([{ type: 'message', id: 'e9', message: { role: 'assistant', content: [] } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionFork', { entryId: 'e9' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'unknown entry');
  // Refused before the command is ever triggered.
  assert.deepEqual(harness.pi.userMessages, []);
});

test('sessionFork rejects a non-message entry that carries a user message', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // A non-message variant that happens to carry a `message` object must not
  // pass the role check: it would only fail later, after `ok:true` was acked.
  ctx.setEntries([{ type: 'compaction', id: 'c9', message: { role: 'user', content: 'x' } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionFork', { entryId: 'c9' });
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'unknown entry');
  assert.deepEqual(harness.pi.userMessages, []);
});

test('a sessionFork for a user entry triggers the fork with the entry id', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setEntries([{ type: 'message', id: 'e3', message: { role: 'user', content: 'hi' } }]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'sessionFork', { entryId: 'e3' });
  assert.equal((parsed(socket).at(-1) as { ok: boolean }).ok, true);
  assert.deepEqual(
    harness.pi.userMessages.map((message) => message.content),
    [`/${SESSION_COMMAND_NAME} fork e3`],
  );
  const handler = harness.pi.registeredCommands[0]!.options.handler;
  const cmdCtx = new StubCommandCtx();
  await handler('fork e3', cmdCtx);
  assert.deepEqual(cmdCtx.calls, ['fork']);
});

test('listTree projects the real session tree into relinked, role-tagged nodes', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setTree([
    {
      entry: { type: 'message', id: 'u1', message: { role: 'user', content: 'first' } },
      children: [
        {
          entry: { type: 'compaction', id: 'c1' },
          children: [
            {
              entry: {
                type: 'message',
                id: 'u2',
                message: {
                  role: 'user',
                  content: [
                    { type: 'text', text: 'second ' },
                    { type: 'image', data: 'AAAA' },
                  ],
                },
              },
              children: [
                {
                  entry: {
                    type: 'message',
                    id: 'a1',
                    message: { role: 'assistant', content: [{ type: 'toolCall', id: 't1' }] },
                  },
                  children: [
                    {
                      entry: {
                        type: 'message',
                        id: 'tr1',
                        message: { role: 'toolResult', toolCallId: 't1', content: [] },
                      },
                      children: [
                        {
                          entry: { type: 'message', id: 'u3', message: { role: 'user', content: 'third' } },
                          children: [],
                        },
                      ],
                    },
                  ],
                },
                // A malformed node: entry.message is missing. Skipped, never
                // thrown; the projection is called inside dispatch, where a
                // throw would surface as a generic refusal.
                { entry: { type: 'message', id: 'bad' }, children: [] },
              ],
            },
          ],
        },
      ],
    },
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1) as {
    ok: boolean;
    tree: TreeNodeSummary[];
    treeTruncated: boolean;
  };
  assert.equal(result.ok, true);
  // Non-message entries are traversed but not emitted, and a message node's
  // parent is its nearest EMITTED ancestor — so u2 relinks past the compaction
  // to u1, and u3 relinks past the toolResult to a1.
  assert.deepEqual(result.tree, [
    { id: 'u1', parentId: null, role: 'user', text: 'first' },
    { id: 'u2', parentId: 'u1', role: 'user', text: 'second [image]' },
    { id: 'a1', parentId: 'u2', role: 'assistant', text: '' },
    { id: 'u3', parentId: 'a1', role: 'user', text: 'third' },
  ]);
  assert.equal(result.treeTruncated, false);
});

/** The projected text of one message node, via the real tree projection. */
function treeTextFor(role: 'user' | 'assistant', content: unknown): string {
  const { nodes } = projectTree([
    { entry: { type: 'message', id: 'n1', message: { role, content } }, children: [] },
  ]);
  return nodes[0]?.text ?? '<missing node>';
}

test('an assistant turn with thinking and tool calls is labelled by its tool names', () => {
  // A turn that ran tools before writing any prose used to project to an empty
  // string and read as "(empty message)" in the app. It is labelled by the
  // tools that ran instead — pi labels such rows the same way.
  const text = treeTextFor('assistant', [
    { type: 'thinking', thinking: 'let me look' },
    { type: 'toolCall', id: 't1', name: 'ls', arguments: {} },
    { type: 'toolCall', id: 't2', name: 'grep', arguments: {} },
  ]);
  assert.equal(text, '(tool calls: ls, grep)');
});

test('repeated tool names are deduplicated in first-seen order', () => {
  const text = treeTextFor('assistant', [
    { type: 'toolCall', id: 't1', name: 'ls' },
    { type: 'toolCall', id: 't2', name: 'grep' },
    { type: 'toolCall', id: 't3', name: 'ls' },
  ]);
  assert.equal(text, '(tool calls: ls, grep)');
});

test('a thinking-only assistant turn is labelled (thinking)', () => {
  const text = treeTextFor('assistant', [{ type: 'thinking', thinking: 'hmm' }]);
  assert.equal(text, '(thinking)');
});

test('an assistant turn with text is unchanged by the empty-turn fallback', () => {
  // The fallback is for the empty case ONLY: a text-bearing turn must not gain
  // a tool-name suffix and must not lose its text.
  const text = treeTextFor('assistant', [
    { type: 'thinking', thinking: 'hmm' },
    { type: 'text', text: 'done' },
    { type: 'toolCall', id: 't1', name: 'ls' },
  ]);
  assert.equal(text, 'done');
});

test("a user message's projection is unchanged, image markers and all", () => {
  const text = treeTextFor('user', [
    { type: 'text', text: 'look ' },
    { type: 'image', data: 'AAAA' },
    { type: 'text', text: ' here' },
  ]);
  assert.equal(text, 'look [image] here');
});

test('listTree keeps the newest 200 nodes and repairs the dangling parent', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  let chain: unknown[] = [];
  for (let index = 204; index >= 0; index -= 1) {
    chain = [
      {
        entry: { type: 'message', id: `n${index}`, message: { role: 'user', content: `m${index}` } },
        children: chain,
      },
    ];
  }
  ctx.setTree(chain);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1) as {
    tree: TreeNodeSummary[];
    treeTruncated: boolean;
  };
  assert.equal(result.treeTruncated, true);
  assert.equal(result.tree.length, 200);
  assert.equal(result.tree[0]!.id, 'n5');
  // n5's parent (n4) was dropped, so it must not point at a missing id.
  assert.equal(result.tree[0]!.parentId, null);
  assert.equal(result.tree.at(-1)!.id, 'n204');
});

test('listTree refuses when pi has no getTree', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete (ctx.sessionManager as { getTree?: unknown }).getTree;
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'tree unavailable');
});

test('listTree projects an empty tree as no nodes and not truncated', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // A fresh session legitimately has no message entries yet — that is an empty
  // picker, never an error and never a truncation.
  ctx.setTree([]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1) as {
    ok: boolean;
    tree: unknown[];
    treeTruncated: boolean;
  };
  assert.equal(result.ok, true);
  assert.deepEqual(result.tree, []);
  assert.equal(result.treeTruncated, false);
});

test('listTree carries the current leaf id', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setLeafId('t1');
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1)!;
  assert.ok('leafId' in result, 'the listTree result must carry leafId');
  assert.equal(result.leafId, 't1');
});

test('listTree reports a null leaf when there is none', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setLeafId(null);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1)!;
  // The key must be present and explicitly null: absent means "an older
  // bridge", which the app cannot tell from "at the root".
  assert.ok('leafId' in result, 'the listTree result must carry leafId');
  assert.equal(result.leafId, null);
});

test("listCommands omits the bridge's own session command", async () => {
  const harness = makeHarness();
  // pi exposes registered extension commands through `getCommands()`; the
  // bridge's own command must never appear in the app's `/` overlay. The filter
  // hides the bare name and pi's `:N` duplicate form only — a hypothetical
  // `pi-droid-session-foo` is still a real, distinct command.
  harness.pi.commands = [
    { name: SESSION_COMMAND_NAME },
    { name: `${SESSION_COMMAND_NAME}:2` },
    { name: `${SESSION_COMMAND_NAME}-foo` },
    { name: 'ping' },
  ];
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listCommands');
  const result = parsed(socket).at(-1) as { commands: Array<{ name: string }> };
  assert.deepEqual(
    result.commands.map((command) => command.name),
    [`${SESSION_COMMAND_NAME}-foo`, 'ping'],
  );
});

test('after a session switch the previous session id is refused as a mismatch', async () => {
  const harness = makeHarness();
  harness.start('tui', 'sess-1', 'startup');
  harness.sockets[0]!.open();
  const secondCtx = harness.start('tui', 'sess-2', 'startup');
  const secondSocket = harness.sockets[1]!;
  secondSocket.open();
  // A stale id from before the replacement must not be dispatched against the
  // successor context. `sendCommand` hardcodes `sess-1`, which is exactly the
  // stale id under test.
  await sendCommand(harness.pi, secondSocket, 'abort');
  const result = parsed(secondSocket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'session mismatch');
  assert.equal(secondCtx.aborts(), 0);
  assert.equal(secondCtx.compacts(), 0);
});

test('commands arriving after shutdown are ignored', async () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('session_shutdown')!({ type: 'session_shutdown' }, harness.startCtx);
  await sendCommand(harness.pi, socket, 'prompt', { text: 'late' });
  assert.deepEqual(harness.pi.userMessages, []);
});

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

test('the bridge does not import the ws package', () => {
  const source = readFileSync(new URL('./pi-droid-bridge.ts', import.meta.url), 'utf8');
  assert.equal(/from\s+['"]ws['"]/.test(source), false);
  assert.equal(/require\(\s*['"]ws['"]\s*\)/.test(source), false);
});

// ---------------------------------------------------------------------------
// History projection
// ---------------------------------------------------------------------------

test('projectHistory keeps the newest entries when it truncates', () => {
  const entries = Array.from({ length: 100 }, (_value, index) => ({ id: index, text: 'x'.repeat(200) }));
  const projection = projectHistory(entries, 1024);
  assert.equal(projection.truncated, true);
  assert.ok(Buffer.byteLength(JSON.stringify(projection.entries)) <= 1024);
  assert.deepEqual(
    projection.entries.at(-1),
    entries.at(-1),
    'the newest entry must survive: a re-subscribe replays this window',
  );
  assert.ok(
    !projection.entries.includes(entries[0]),
    'the oldest entry is the one to drop',
  );
  // Order is chronological: the app appends these as later rows.
  const ids = projection.entries.map((entry) => (entry as { id: number }).id);
  assert.deepEqual(ids, [...ids].sort((a, b) => a - b));
});

test('projectHistory collapses an entry too large to ever fit, and keeps walking', () => {
  const huge = { id: 'huge', text: 'x'.repeat(4096) };
  const entries = [{ id: 'old' }, huge, { id: 'new' }];
  const projection = projectHistory(entries, 2048);
  assert.equal(
    projection.truncated,
    false,
    'the giant is collapsed, not dropped, so no older entry is omitted',
  );
  assert.deepEqual(projection.entries[0], { id: 'old' });
  assert.deepEqual(projection.entries[1], {
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(huge)),
  });
  assert.deepEqual(projection.entries[2], { id: 'new' });
  assert.ok(Buffer.byteLength(JSON.stringify(projection.entries)) <= 2048);
});

test('an oversized history entry with an image keeps its text', () => {
  const image = { type: 'image', data: 'A'.repeat(4096) };
  const entry = {
    type: 'message',
    message: { role: 'user', content: [{ type: 'text', text: 'hi' }, image] },
  };
  const projection = projectHistory([entry], 2048);
  assert.equal(projection.entries.length, 1);
  const kept = projection.entries[0] as { message?: { content?: unknown[] } };
  // Not the whole-entry marker: the trim rescued it and rebuilt the wrapper.
  assert.notDeepEqual(kept, { truncated: true, bytes: Buffer.byteLength(JSON.stringify(entry)) });
  assert.deepEqual(kept.message?.content?.[0], { type: 'text', text: 'hi' });
  assert.deepEqual(kept.message?.content?.[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(image)),
  });
});

// PIN: green today. NC-8 omits the marker fallback before the `break`.
test('a trimmed history entry that still does not fit the window falls back to the marker and the walk continues', () => {
  const smallOld = { id: 'old' };
  const smallNewest = { id: 'new', text: 'n'.repeat(600) };
  const bigImageMsg = {
    role: 'user',
    content: [{ type: 'text', text: 't'.repeat(1500) }, { type: 'image', data: 'A'.repeat(5000) }],
  };
  const projection = projectHistory([smallOld, bigImageMsg, smallNewest], 2048);
  // The trim fits the entry on its own, but not the *remaining* window after the
  // newest entry. The marker fallback must run before the break so the older
  // entry survives and the window flag stays false.
  assert.equal(projection.truncated, false);
  assert.deepEqual(projection.entries[0], smallOld);
  assert.deepEqual(projection.entries[1], {
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(bigImageMsg)),
  });
  assert.deepEqual(projection.entries[2], smallNewest);
});

test('projectHistory collapses a giant even when it is the newest entry', () => {
  const huge = { id: 'huge', text: 'x'.repeat(4096) };
  const projection = projectHistory([{ id: 'old' }, huge], 2048);
  assert.equal(projection.truncated, false);
  assert.deepEqual(projection.entries, [
    { id: 'old' },
    { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) },
  ]);

  // Only the giant: the window may then hold exactly one marker, and the
  // comma term must not be charged for it.
  const alone = projectHistory([huge], 2048);
  assert.deepEqual(alone, {
    entries: [{ truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) }],
    truncated: false,
  });
});

test('projectHistory truncates at the byte cap and flags it', () => {
  const entries = Array.from({ length: 100 }, (_value, index) => ({ id: index, text: 'x'.repeat(200) }));
  const projection = projectHistory(entries, 1024);
  assert.equal(projection.truncated, true);
  assert.ok(Buffer.byteLength(JSON.stringify(projection.entries)) <= 1024);
  assert.ok(projection.entries.length < entries.length);
});

test('projectHistory keeps everything under the cap', () => {
  const entries = [{ id: 1 }, { id: 2 }];
  const projection = projectHistory(entries, 1024);
  assert.deepEqual(projection, { entries, truncated: false });
});

// ---------------------------------------------------------------------------
// Endpoint discovery
// ---------------------------------------------------------------------------

test('readEndpoint reads the agent port from discovery and the token from config', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-rt-'));
  const configDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-cfg-'));
  try {
    writeDiscovery(runtimeDir, {
      agentPort: 4321,
      viewerPort: 8787,
      pid: process.pid,
      startedAt: new Date().toISOString(),
      protocolVersion: PROTOCOL_VERSION,
    });
    const { token } = loadOrCreateToken(configDir);
    assert.deepEqual(readEndpoint({ runtimeDir, configDir }), {
      url: 'ws://127.0.0.1:4321',
      token,
    });
  } finally {
    rmSync(runtimeDir, { recursive: true, force: true });
    rmSync(configDir, { recursive: true, force: true });
  }
});

test('readEndpoint reports no hub when there is no discovery file', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-rt-'));
  const configDir = mkdtempSync(join(tmpdir(), 'pi-droid-bridge-cfg-'));
  try {
    assert.equal(readEndpoint({ runtimeDir, configDir }), null);
  } finally {
    rmSync(runtimeDir, { recursive: true, force: true });
    rmSync(configDir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Settle snippet (the notification body)
// ---------------------------------------------------------------------------

/** The last `settled` payload in a socket's sent frames, if any. */
function settlePayload(
  socket: FakeSocket,
  from = 0,
): { kind: string; text: string; truncated: boolean } | undefined {
  return parsed(socket)
    .slice(from)
    .map((message) => message.payload as { kind?: string })
    .filter((payload) => payload?.kind === 'settled')
    .at(-1) as { kind: string; text: string; truncated: boolean } | undefined;
}

test('settleText keeps text at the cap and flags one code point over', () => {
  assert.deepEqual(settleText('abc', 3), { text: 'abc', truncated: false });
  assert.deepEqual(settleText('abcd', 3), { text: 'abc', truncated: true });
});

test('agent_settled emits the assistant text cached from message_end', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  harness.pi.handlers.get('message_end')!(
    { type: 'message_end', message: { role: 'assistant', content: 'the answer' } },
    harness.startCtx,
  );
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  const emitted = parsed(socket).slice(before);
  assert.deepEqual(
    emitted.map((m) => (m.payload as { kind?: string }).kind),
    ['agent', 'usage', 'settled'],
  );
  assert.deepEqual(emitted[2]!.payload, {
    kind: 'settled',
    text: 'the answer',
    truncated: false,
  });
});

test('an oversized assistant message_end still yields its text, flagged truncated', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const huge = { role: 'assistant', content: 'x'.repeat(MAX_RELAY_BYTES + 100) };
  harness.pi.handlers.get('message_end')!(
    { type: 'message_end', message: huge },
    harness.startCtx,
  );
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  const settled = settlePayload(socket, before)!;
  // The bounded message is replaced by a `{truncated:true,bytes}` marker; the
  // snippet must come from the original message, so it is never the fallback.
  assert.ok(settled.text.length > 0, 'must not fall back to empty');
  assert.ok(
    Array.from(settled.text).length <= SETTLED_TEXT_MAX_CODE_POINTS,
    'must respect the wire cap',
  );
  assert.equal(settled.truncated, true);
});

test('a user message_end does not clobber the cached assistant text', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    { type: 'message_end', message: { role: 'assistant', content: 'the answer' } },
    harness.startCtx,
  );
  handler({ type: 'message_end', message: { role: 'user', content: 'steer' } }, harness.startCtx);
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  assert.deepEqual(settlePayload(socket, before), {
    kind: 'settled',
    text: 'the answer',
    truncated: false,
  });
});

test('a toolResult message_end does not clobber the cached assistant text', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    { type: 'message_end', message: { role: 'assistant', content: 'the answer' } },
    harness.startCtx,
  );
  handler(
    { type: 'message_end', message: { role: 'toolResult', content: 'output' } },
    harness.startCtx,
  );
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  assert.deepEqual(settlePayload(socket, before), {
    kind: 'settled',
    text: 'the answer',
    truncated: false,
  });
});

test("a second turn's settle carries only the second turn's text", () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    { type: 'message_end', message: { role: 'assistant', content: 'first' } },
    harness.startCtx,
  );
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  harness.pi.handlers.get('agent_start')!({ type: 'agent_start' }, harness.startCtx);
  handler(
    { type: 'message_end', message: { role: 'assistant', content: 'second' } },
    harness.startCtx,
  );
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  assert.deepEqual(settlePayload(socket, before), {
    kind: 'settled',
    text: 'second',
    truncated: false,
  });
});

test('a settle with no assistant message carries empty text', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('agent_settled')!({}, harness.startCtx);
  assert.deepEqual(settlePayload(socket, before), {
    kind: 'settled',
    text: '',
    truncated: false,
  });
});

// ---------------------------------------------------------------------------
// Tool view builders (M2 — bridge normalization)
// ---------------------------------------------------------------------------

function textContent(text: string): unknown {
  return [{ type: 'text', text }];
}

// --- edit ---

test('buildToolView parses an edit diff from details.diff', () => {
  const view = buildToolView({
    name: 'edit',
    args: { path: 'app/foo.dart', edits: [{ oldText: 'old', newText: 'new' }] },
    content: textContent('Successfully replaced 1 block(s) in app/foo.dart.'),
    details: {
      diff: " 1 void main() {\n-2   print('old');\n+2   print('new');\n 3 }",
      patch: 'ignored',
      firstChangedLine: 2,
    },
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'diff',
    path: 'app/foo.dart',
    lines: [
      { kind: 'ctx', text: 'void main() {' },
      { kind: 'del', text: "  print('old');" },
      { kind: 'add', text: "  print('new');" },
      { kind: 'ctx', text: '}' },
    ],
  });
});

test('an edit view uses details.diff whatever shape input.edits has', () => {
  // pi's `prepareEditArguments` accepts an array, a JSON string of an array, a
  // single object, and a legacy top-level oldText/newText. None of that may
  // matter: the diff is `details.diff` or nothing.
  const details = { diff: '+1 added' };
  const shapes: unknown[] = [
    [{ oldText: 'a', newText: 'b' }],
    JSON.stringify([{ oldText: 'a', newText: 'b' }]),
    { oldText: 'a', newText: 'b' },
    [
      { oldText: 'a', newText: 'b' },
      { oldText: 'c', newText: 'd' },
    ],
  ];
  for (const edits of shapes) {
    const view = buildToolView({
      name: 'edit',
      args: { path: 'a.ts', edits },
      content: textContent('Successfully replaced 1 block(s) in a.ts.'),
      details,
      isError: false,
    });
    assert.deepEqual(
      view,
      { type: 'diff', path: 'a.ts', lines: [{ kind: 'add', text: 'added' }] },
      `edits shape ${JSON.stringify(edits)} must not change the view`,
    );
  }
});

test('an edit without a usable details.diff is generic, never a reconstructed diff', () => {
  for (const details of [undefined, {}, { diff: '' }, { diff: 42 }]) {
    const view = buildToolView({
      name: 'edit',
      args: { path: 'a.ts', edits: [{ oldText: 'old', newText: 'new' }] },
      content: textContent('Successfully replaced 1 block(s) in a.ts.'),
      details: details as Record<string, unknown> | undefined,
      isError: false,
    });
    assert.equal(view.type, 'generic');
    assert.equal((view as GenericView).target, 'a.ts');
  }
});

// --- write ---

test('a write view is an all-addition diff claiming no line delta', () => {
  const view = buildToolView({
    name: 'write',
    args: { path: 'app/new.dart', content: 'line one\nline two\n' },
    content: textContent('Successfully wrote to app/new.dart'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'diff',
    path: 'app/new.dart',
    lines: [
      { kind: 'add', text: 'line one' },
      { kind: 'add', text: 'line two' },
    ],
  });
  // There is no old file to diff against, so no `+N −M` line delta may be
  // fabricated anywhere in the view. (The one-line summary is app-side; this
  // pins the bridge half of the rule.)
  assert.doesNotMatch(JSON.stringify(view), /[+−]\d/);
});

test('a write of empty content is a diff view with zero lines', () => {
  const view = buildToolView({
    name: 'write',
    args: { path: 'empty.txt', content: '' },
    content: textContent('Successfully wrote to empty.txt'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, { type: 'diff', path: 'empty.txt', lines: [] });
});

// --- read ---

test('a read view carries the path, content and the requested range', () => {
  const view = buildToolView({
    name: 'read',
    args: { path: 'app/foo.dart', offset: 2, limit: 3 },
    content: textContent('line two\nline three\nline four'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'file',
    path: 'app/foo.dart',
    content: 'line two\nline three\nline four',
    startLine: 2,
    endLine: 4,
  });
});

test('a read stopped by the user limit derives its range from input.offset/limit', () => {
  const view = buildToolView({
    name: 'read',
    args: { path: 'big.ts', limit: 3 },
    content: textContent('line one\n\n[3 more lines in file. Use offset=4 to continue.]'),
    details: undefined,
    isError: false,
  });
  assert.equal(view.type, 'file');
  assert.equal((view as FileView).startLine, 1);
  assert.equal((view as FileView).endLine, 3);
});

test('a pi-truncated read derives its range from the continuation notice', () => {
  const view = buildToolView({
    name: 'read',
    args: { path: 'big.ts' },
    content: textContent('line 10\nline 11\n\n[Showing lines 10-11 of 100. Use offset=12 to continue.]'),
    details: { truncation: { truncated: true } },
    isError: false,
  });
  assert.equal(view.type, 'file');
  assert.equal((view as FileView).startLine, 10);
  assert.equal((view as FileView).endLine, 11);
});

test('an image read is generic, never a text file view', () => {
  const view = buildToolView({
    name: 'read',
    args: { path: 'pic.png' },
    content: [
      { type: 'text', text: 'Read image file [image/png]' },
      { type: 'image', data: 'AAAA', mimeType: 'image/png' },
    ],
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, { type: 'generic', target: 'pic.png' });
});

// --- bash ---

test('a successful bash view shows the command, merged output and exit 0', () => {
  const view = buildToolView({
    name: 'bash',
    args: { command: 'ls -1' },
    content: textContent('README.md\npackage.json\n'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'command',
    command: 'ls -1',
    output: 'README.md\npackage.json\n',
    exitCode: 0,
  });
});

test('a bash failure parses exitCode only from a trailing Command exited with code N', () => {
  const view = buildToolView({
    name: 'bash',
    args: { command: 'false' },
    content: textContent('some output\n\nCommand exited with code 3'),
    details: undefined,
    isError: true,
  });
  assert.equal(view.type, 'command');
  assert.equal((view as CommandView).exitCode, 3);
});

test('aborted, timed-out and signalled bash carry no exit code', () => {
  const texts = [
    'Command aborted',
    'output\n\nCommand timed out after 12 seconds',
    'output\n\nCommand terminated without an exit code',
  ];
  for (const text of texts) {
    const view = buildToolView({
      name: 'bash',
      args: { command: 'sleep 99' },
      content: textContent(text),
      details: undefined,
      isError: true,
    });
    assert.equal(view.type, 'command');
    assert.equal((view as CommandView).exitCode, undefined, `${text} must not yield a code`);
  }
});

// --- grep ---

test('a grep view flattens match and context lines into file/line/text', () => {
  const view = buildToolView({
    name: 'grep',
    args: { pattern: 'print' },
    content: textContent(
      'src/a.ts:12: const x = 1;\nsrc/a.ts-13- const y = 2;\nsrc/b.ts:4: other;',
    ),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'matches',
    matches: [
      { file: 'src/a.ts', line: 12, text: 'const x = 1;' },
      { file: 'src/a.ts', line: 13, text: 'const y = 2;' },
      { file: 'src/b.ts', line: 4, text: 'other;' },
    ],
  });
});

test('grep paths containing a colon or a Windows drive parse correctly', () => {
  const view = buildToolView({
    name: 'grep',
    args: { pattern: 'x' },
    content: textContent('src/a:b.ts:12: text\nC:\\proj\\a.ts:7: win'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual((view as MatchesView).matches, [
    { file: 'src/a:b.ts', line: 12, text: 'text' },
    { file: 'C:\\proj\\a.ts', line: 7, text: 'win' },
  ]);
});

test('a grep body containing a further line-number pattern does not steal it', () => {
  const view = buildToolView({
    name: 'grep',
    args: { pattern: 'x' },
    content: textContent(
      "src/a.ts:12: const s = ': 34: x';\nsrc/a.ts:12: see foo:34: here",
    ),
    details: undefined,
    isError: false,
  });
  // The path is the non-greedy prefix and the first `:N: ` wins; a greedy path
  // would consume up to the trailing `:34:` and report line 34.
  assert.deepEqual((view as MatchesView).matches, [
    { file: 'src/a.ts', line: 12, text: "const s = ': 34: x';" },
    { file: 'src/a.ts', line: 12, text: 'see foo:34: here' },
  ]);
});

test('grep drops notice lines and yields an empty view for No matches found', () => {
  const withNotice = buildToolView({
    name: 'grep',
    args: { pattern: 'x' },
    content: textContent(
      'src/a.ts:1: hit\n\n[100 matches limit reached. Use limit=200 for more, or refine pattern]',
    ),
    details: { matchLimitReached: 100 },
    isError: false,
  });
  assert.deepEqual((withNotice as MatchesView).matches, [
    { file: 'src/a.ts', line: 1, text: 'hit' },
  ]);

  const empty = buildToolView({
    name: 'grep',
    args: { pattern: 'x' },
    content: textContent('No matches found'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(empty, { type: 'matches', matches: [] });
});

// --- find ---

test('a find view lists matching files and yields an empty view for a miss', () => {
  const view = buildToolView({
    name: 'find',
    args: { pattern: '*.ts' },
    content: textContent('src/a.ts\nsrc/b.ts'),
    details: undefined,
    isError: false,
  });
  // find reuses the matches view: a file match has no line, so line 0 and empty
  // text mark it (there is no dedicated files view in the contract).
  assert.deepEqual((view as MatchesView).matches, [
    { file: 'src/a.ts', line: 0, text: '' },
    { file: 'src/b.ts', line: 0, text: '' },
  ]);
  const empty = buildToolView({
    name: 'find',
    args: { pattern: '*.ts' },
    content: textContent('No files found matching pattern'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(empty, { type: 'matches', matches: [] });
});

// --- ls ---

test('an ls view is a name/type table', () => {
  const view = buildToolView({
    name: 'ls',
    args: { path: '.' },
    content: textContent('app/\nREADME.md\n.gitignore'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'table',
    columns: ['name', 'type'],
    rows: [
      ['app', 'directory'],
      ['README.md', 'file'],
      ['.gitignore', 'file'],
    ],
  });
});

test('an empty directory is an empty table, not generic', () => {
  const view = buildToolView({
    name: 'ls',
    args: { path: 'empty' },
    content: textContent('(empty directory)'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, { type: 'table', columns: ['name', 'type'], rows: [] });
});

// --- generic ---

test('a custom tool falls back to a generic view carrying its target', () => {
  const withPath = buildToolView({
    name: 'my-tool',
    args: { path: 'x.ts', other: 1 },
    content: textContent('did the thing'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(withPath, { type: 'generic', target: 'x.ts' });

  const bare = buildToolView({
    name: 'my-tool',
    args: {},
    content: textContent('x'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(bare, { type: 'generic' });
});

// ---------------------------------------------------------------------------
// Payload construction and bounding
// ---------------------------------------------------------------------------

test('toolCallPayloads builds a running payload (and an input-only write diff)', () => {
  const message = {
    role: 'assistant',
    content: [
      { type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'a.ts' } },
      { type: 'toolCall', id: 'call-2', name: 'write', arguments: { path: 'b.ts', content: 'x' } },
    ],
  };
  const payloads = toolCallPayloads(message, new Map());
  assert.deepEqual(payloads, [
    { kind: 'tool', toolCallId: 'call-1', name: 'read', status: 'running', view: { type: 'generic', target: 'a.ts' } },
    { kind: 'tool', toolCallId: 'call-2', name: 'write', status: 'running', view: { type: 'diff', path: 'b.ts', lines: [{ kind: 'add', text: 'x' }] } },
  ]);
});

test('toolResultPayload builds a done/error payload from the full view', () => {
  const done = toolResultPayload(
    {
      role: 'toolResult',
      toolCallId: 'call-1',
      toolName: 'read',
      content: [{ type: 'text', text: 'body' }],
      isError: false,
    },
    new Map([['call-1', { path: 'a.ts' }]]),
  );
  assert.deepEqual(done, {
    kind: 'tool',
    toolCallId: 'call-1',
    name: 'read',
    status: 'done',
    view: { type: 'file', path: 'a.ts', content: 'body' },
  });

  const errored = toolResultPayload(
    {
      role: 'toolResult',
      toolCallId: 'call-2',
      toolName: 'bash',
      content: [{ type: 'text', text: 'boom' }],
      isError: true,
    },
    new Map([['call-2', { command: 'false' }]]),
  );
  assert.equal(errored!.status, 'error');
  assert.deepEqual(errored!.view, { type: 'command', command: 'false', output: 'boom' });
});

test('boundToolPayload trims a bulk view to TOOL_VIEW_MAX_BYTES and flags it', () => {
  const lines = Array.from({ length: 5000 }, (_value, index) => ({
    kind: 'add' as const,
    text: `line ${index} ${'x'.repeat(40)}`,
  }));
  const payload: ToolPayload = {
    kind: 'tool',
    toolCallId: 'c1',
    name: 'edit',
    status: 'done',
    view: { type: 'diff', path: 'big.txt', lines },
  };
  const bounded = boundToolPayload(payload);
  assert.ok(Buffer.byteLength(JSON.stringify(bounded)) <= TOOL_VIEW_MAX_BYTES);
  assert.equal(bounded.view!.truncated, true);
  assert.ok((bounded.view as DiffView).lines.length < 5000);
  assert.ok((bounded.view as DiffView).lines.length > 0);
  assert.ok((bounded.view as DiffView).lines.length <= TOOL_VIEW_MAX_LINES);
});

test('boundToolPayload leaves an under-cap view untouched', () => {
  const payload: ToolPayload = {
    kind: 'tool',
    toolCallId: 'c1',
    name: 'edit',
    status: 'done',
    view: { type: 'diff', path: 'a', lines: [{ kind: 'add', text: 'x' }] },
  };
  const bounded = boundToolPayload(payload);
  assert.deepEqual(bounded, payload);
  assert.equal(bounded.view!.truncated, undefined);
});

test('boundToolPayload flags a view trimmed purely by the line cap', () => {
  const lines = Array.from({ length: 2500 }, () => ({ kind: 'add' as const, text: 'x' }));
  const payload: ToolPayload = {
    kind: 'tool',
    toolCallId: 'c1',
    name: 'edit',
    status: 'done',
    view: { type: 'diff', path: 'a', lines },
  };
  // Precondition: under the byte cap, so only the line cap can trigger a trim.
  assert.ok(Buffer.byteLength(JSON.stringify(payload)) <= TOOL_VIEW_MAX_BYTES);
  const bounded = boundToolPayload(payload);
  assert.equal((bounded.view as DiffView).lines.length, TOOL_VIEW_MAX_LINES);
  assert.equal(bounded.view!.truncated, true);
});

// ---------------------------------------------------------------------------
// History annotation
// ---------------------------------------------------------------------------

test('annotateToolViews injects a running frame after each call and a done frame after each result', () => {
  const assistant = {
    type: 'message',
    message: {
      role: 'assistant',
      content: [{ type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'a.ts' } }],
    },
  };
  const result = {
    type: 'message',
    message: {
      role: 'toolResult',
      toolCallId: 'call-1',
      toolName: 'read',
      content: [{ type: 'text', text: 'file body' }],
      isError: false,
    },
  };
  const note = { type: 'note', id: 'n1' };
  const annotated = annotateToolViews([assistant, result, note]);
  assert.equal(annotated.length, 5);
  assert.equal(annotated[0], assistant);
  assert.deepEqual(annotated[1], {
    kind: 'tool',
    toolCallId: 'call-1',
    name: 'read',
    status: 'running',
    view: { type: 'generic', target: 'a.ts' },
  });
  assert.equal(annotated[2], result);
  // Args come only from the earlier assistant message; the result carries none.
  assert.deepEqual(annotated[3], {
    kind: 'tool',
    toolCallId: 'call-1',
    name: 'read',
    status: 'done',
    view: { type: 'file', path: 'a.ts', content: 'file body' },
  });
  assert.equal(annotated[4], note);
});

test('annotateToolViews bounds each inserted payload', () => {
  const hugeContent = Array.from(
    { length: 5000 },
    (_value, index) => `line ${index} ${'y'.repeat(40)}`,
  ).join('\n');
  const assistant = {
    type: 'message',
    message: {
      role: 'assistant',
      content: [
        { type: 'toolCall', id: 'c1', name: 'write', arguments: { path: 'big.txt', content: hugeContent } },
      ],
    },
  };
  const annotated = annotateToolViews([assistant]);
  const tool = annotated[1] as ToolPayload;
  assert.equal(tool.kind, 'tool');
  assert.ok(Buffer.byteLength(JSON.stringify(tool)) <= TOOL_VIEW_MAX_BYTES);
  assert.equal(tool.view!.truncated, true);
});

// ---------------------------------------------------------------------------
// Live wiring and history replay
// ---------------------------------------------------------------------------

test('a message_end emits its tool frames after the message, in order', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    {
      type: 'message_end',
      message: {
        role: 'assistant',
        content: [{ type: 'toolCall', id: 'call-1', name: 'bash', arguments: { command: 'echo hi' } }],
      },
    },
    harness.startCtx,
  );
  handler(
    {
      type: 'message_end',
      message: {
        role: 'toolResult',
        toolCallId: 'call-1',
        toolName: 'bash',
        content: [{ type: 'text', text: 'hi\n' }],
        isError: false,
      },
    },
    harness.startCtx,
  );
  const frames = parsed(socket).slice(before).map((m) => m.payload as ToolPayload);
  assert.deepEqual(
    frames.map((frame) => frame.kind),
    ['message', 'tool', 'message', 'tool'],
  );
  assert.equal(frames[1]!.status, 'running');
  assert.equal(frames[1]!.name, 'bash');
  assert.deepEqual(frames[1]!.view, { type: 'generic', target: 'echo hi' });
  assert.equal(frames[3]!.status, 'done');
  assert.deepEqual(frames[3]!.view, {
    type: 'command',
    command: 'echo hi',
    output: 'hi\n',
    exitCode: 0,
  });
});

test('a resumed session resolves a toolResult from entries seeded at session_start', () => {
  const harness = makeHarness();
  const ctx = makeCtx();
  ctx.setEntries([
    {
      type: 'message',
      message: {
        role: 'assistant',
        content: [{ type: 'toolCall', id: 'call-9', name: 'read', arguments: { path: 'seeded.ts' } }],
      },
    },
  ]);
  harness.pi.handlers.get('session_start')!({ type: 'session_start', reason: 'startup' }, ctx);
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('message_end')!(
    {
      type: 'message_end',
      message: {
        role: 'toolResult',
        toolCallId: 'call-9',
        toolName: 'read',
        content: [{ type: 'text', text: 'body' }],
        isError: false,
      },
    },
    ctx,
  );
  const tool = parsed(socket)
    .slice(before)
    .map((m) => m.payload as ToolPayload)
    .find((payload) => payload?.kind === 'tool')!;
  assert.deepEqual(tool.view, { type: 'file', path: 'seeded.ts', content: 'body' });
});

test('a completed call in the entries is not seeded (its later result renders without arguments)', () => {
  const harness = makeHarness();
  const ctx = makeCtx();
  ctx.setEntries([
    {
      type: 'message',
      message: {
        role: 'assistant',
        content: [
          { type: 'toolCall', id: 'call-9', name: 'write',
            arguments: { path: 'done.ts', content: 'SENTINEL' } },
        ],
      },
    },
    {
      type: 'message',
      message: {
        role: 'toolResult', toolCallId: 'call-9', toolName: 'write',
        content: [{ type: 'text', text: 'wrote done.ts' }], isError: false,
      },
    },
  ]);
  harness.pi.handlers.get('session_start')!({ type: 'session_start', reason: 'reload' }, ctx);
  const socket = harness.sockets[0]!;
  socket.open();
  const before = socket.sent.length;
  harness.pi.handlers.get('message_end')!(
    {
      type: 'message_end',
      message: {
        role: 'toolResult', toolCallId: 'call-9', toolName: 'write',
        content: [{ type: 'text', text: 'wrote done.ts' }], isError: false,
      },
    },
    ctx,
  );
  const tool = parsed(socket).slice(before).map((m) => m.payload as ToolPayload)
    .find((payload) => payload?.kind === 'tool')!;
  assert.ok(tool);
  assert.equal(tool.status, 'done');
  assert.deepEqual(tool.view, { type: 'generic' });
});

test('a live call’s arguments are released once its result has been emitted', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    {
      type: 'message_end',
      message: {
        role: 'assistant',
        content: [{ type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'a.ts' } }],
      },
    },
    harness.startCtx,
  );
  handler(
    {
      type: 'message_end',
      message: {
        role: 'toolResult', toolCallId: 'call-1', toolName: 'read',
        content: [{ type: 'text', text: 'body' }], isError: false,
      },
    },
    harness.startCtx,
  );
  const first = parsed(socket).map((m) => m.payload as ToolPayload)
    .filter((payload) => payload?.kind === 'tool' && payload.status === 'done').pop()!;
  assert.deepEqual(first.view, { type: 'file', path: 'a.ts', content: 'body' },
    'the result is paired while the call is still held');
  const before = socket.sent.length;
  // A second result for the same id is the only public observable of the release:
  // a call whose arguments are gone renders with empty args.
  handler(
    {
      type: 'message_end',
      message: {
        role: 'toolResult', toolCallId: 'call-1', toolName: 'read',
        content: [{ type: 'text', text: 'body' }], isError: false,
      },
    },
    harness.startCtx,
  );
  const second = parsed(socket).slice(before).map((m) => m.payload as ToolPayload)
    .find((payload) => payload?.kind === 'tool')!;
  assert.deepEqual(second.view, { type: 'file', path: '', content: 'body' });
});

test('a settled turn releases a call that never produced a result', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  const handler = harness.pi.handlers.get('message_end')!;
  handler(
    {
      type: 'message_end',
      message: {
        role: 'assistant',
        content: [{ type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'a.ts' } }],
      },
    },
    harness.startCtx,
  );
  harness.pi.handlers.get('agent_settled')!({ type: 'agent_settled' }, harness.startCtx);
  const before = socket.sent.length;
  handler(
    {
      type: 'message_end',
      message: {
        role: 'toolResult', toolCallId: 'call-1', toolName: 'read',
        content: [{ type: 'text', text: 'late' }], isError: false,
      },
    },
    harness.startCtx,
  );
  const tool = parsed(socket).slice(before).map((m) => m.payload as ToolPayload)
    .find((payload) => payload?.kind === 'tool')!;
  assert.deepEqual(tool.view, { type: 'file', path: '', content: 'late' });
});

test('fetchHistory replays a history whose entries carry the synthesized tool frames', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setEntries([
    {
      type: 'message',
      message: {
        role: 'assistant',
        content: [{ type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'a.ts' } }],
      },
    },
    {
      type: 'message',
      message: {
        role: 'toolResult',
        toolCallId: 'call-1',
        toolName: 'read',
        content: [{ type: 'text', text: 'body' }],
        isError: false,
      },
    },
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'fetchHistory');
  const history = parsed(socket).find((m) => m.type === 'history')!;
  const entries = history.entries as Array<Record<string, unknown>>;
  const tools = entries.filter((entry) => entry.kind === 'tool');
  assert.deepEqual(tools.map((tool) => tool.status), ['running', 'done']);
  assert.ok(Buffer.byteLength(JSON.stringify(entries)) <= HISTORY_MAX_BYTES);
});

test('a tool-heavy history keeps the newest turns within HISTORY_MAX_BYTES', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const body = 'z'.repeat(4000);
  const entries: unknown[] = [];
  for (let index = 0; index < 250; index += 1) {
    entries.push({
      type: 'message',
      message: {
        role: 'assistant',
        content: [
          { type: 'toolCall', id: `call-${index}`, name: 'read', arguments: { path: `f${index}.txt` } },
        ],
      },
    });
    entries.push({
      type: 'message',
      message: {
        role: 'toolResult',
        toolCallId: `call-${index}`,
        toolName: 'read',
        content: [{ type: 'text', text: body }],
        isError: false,
      },
    });
  }
  ctx.setEntries(entries);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'fetchHistory');
  const history = parsed(socket).find((m) => m.type === 'history')!;
  const kept = history.entries as Array<Record<string, unknown>>;
  assert.ok(Buffer.byteLength(JSON.stringify(kept)) <= HISTORY_MAX_BYTES);
  assert.equal(history.truncated, true, 'a 250-pair tool-heavy session must not fit the window');
  const doneFrames = kept.filter((entry) => entry.kind === 'tool' && entry.status === 'done');
  assert.ok(doneFrames.length > 0, 'the newest turn tools must survive');
  assert.equal(doneFrames.at(-1)!.toolCallId, 'call-249');
});
