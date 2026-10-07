/**
 * Shared fakes and helpers for the bridge tests. Lives under `test/support` and
 * is deliberately not a `*.test.ts` file, so the test runner never collects it;
 * every bridge test file imports the pieces it needs from here.
 *
 * The fake socket, the stub `ExtensionAPI`, the stub command context and the
 * harness are all injected seams: nothing here dials a real socket or spawns a
 * real pi.
 */

import { installBridge } from '../../extensions/pi-handset-bridge.ts';
import type {
  AssistantMessageEvent,
  BridgeCloseEvent,
  BridgeCommandCtx,
  BridgeCtx,
  BridgeDeps,
  BridgeHandler,
  BridgePi,
  BridgeSocket,
  UserMessageContent,
} from '../../src/bridge/pi-types.ts';
import { PROTOCOL_VERSION, type SlashCommand } from '../../src/protocol/protocol.ts';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

export class FakeSocket implements BridgeSocket {
  readyState = 0;
  readonly sent: string[] = [];
  readonly closeCalls: Array<{ code?: number; reason?: string }> = [];
  // `any` because the map holds handlers for unrelated event shapes; the
  // public overloads below are the typed surface.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
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
  // An overload implementation signature has to accept every overload; `any`
  // is what makes the narrower `BridgeCloseEvent` handler assignable.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
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

export class StubPi implements BridgePi {
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
export class StubCommandCtx implements BridgeCommandCtx {
  readonly calls: string[] = [];
  private cancelled = false;
  private error: unknown;
  private used = false;

  private act(method: string): { cancelled: boolean } {
    if (this.used) throw new Error(`command context is stale on ${method}`);
    this.used = true;
    this.calls.push(method);
    // The test configures an arbitrary thrown value on purpose: the bridge is
    // asserted to contain whatever a pi callback throws, Error or not.
    // eslint-disable-next-line @typescript-eslint/only-throw-error
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

export interface TestCtx extends BridgeCtx {
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

export function makeCtx(mode = 'tui', sessionId = 'sess-1'): TestCtx {
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
      // Same as `act` above: an arbitrary thrown value is the subject.
      // eslint-disable-next-line @typescript-eslint/only-throw-error
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

export interface Harness {
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

export function makeHarness(overrides: Partial<BridgeDeps> = {}): Harness {
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
    fireTimer: (index = 0) => timers[index].fn(),
  };
}

export function parsed(socket: FakeSocket): Array<Record<string, unknown>> {
  return socket.sent.map((text) => JSON.parse(text) as Record<string, unknown>);
}

export function tick(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

export async function sendCommand(
  _pi: StubPi,
  socket: FakeSocket,
  name: string,
  args?: unknown,
): Promise<void> {
  socket.message({ protocolVersion: PROTOCOL_VERSION, type: 'command', id: `c-${name}`, sessionId: 'sess-1', name, args });
  await tick();
}
export function sampleAssistantEvent(type: string): AssistantMessageEvent {
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
/** One image content part carrying `size` bytes of fake base64. */
export function imagePart(size: number, mimeType = 'image/png'): Record<string, unknown> {
  return { type: 'image', data: 'A'.repeat(size), mimeType };
}
