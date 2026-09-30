/**
 * pi-droid bridge — a pi extension that attaches the running session to the hub.
 *
 * The bridge is a *client*: it discovers the hub's ephemeral loopback port in
 * the discovery file, authenticates with the persisted token, registers its
 * session, and relays normalized events. It never exposes pi's own event shapes
 * to the wire and it never dials in the factory — the socket is opened in
 * `session_start` and closed in an idempotent `session_shutdown`.
 *
 * Transport is Node's native `WebSocket` global (client only). `ws` is a server
 * dependency of the hub and is deliberately not imported here. The socket
 * factory, the clock, the RNG, the endpoint resolver and the debug sink are all
 * injectable so the tests never dial and never sleep.
 *
 * # Why the types are structural
 *
 * A type-only import of `@earendil-works/pi-coding-agent` would make `pc/`
 * depend on the host package just to typecheck, and `pc/` is a standalone
 * package. Instead the bridge declares the small slice of `ExtensionAPI`,
 * `ExtensionContext` and `AssistantMessageEvent` it actually touches. The
 * `AssistantMessageEvent` union below is transcribed from
 * `pi-ai/dist/types.d.ts`. The `never` assignment in `normalizeAssistantEvent`'s
 * exhaustive switch only guards that *local transcription*: a variant added or
 * removed there is a compile error, but a 13th variant in real pi compiles green
 * because the live event is cast into this local union. The production
 * protection is the runtime `default`, which turns any unknown variant into an
 * explicit ignore rather than a silent `undefined`.
 */

import { loadOrCreateToken, resolveConfigDir } from '../src/hub/auth.ts';
import { readDiscovery, resolveRuntimeDir } from '../src/hub/discovery.ts';
import {
  MAX_RELAY_BYTES,
  PROTOCOL_VERSION,
  asObject,
  asString,
  encode,
} from '../src/protocol/protocol.ts';
import type {
  AgentState,
  AgentToHubMessage,
  CommandMessage,
  CommandResultMessage,
  EventMessage,
  EventPayload,
  HistoryMessage,
  RegisterMessage,
} from '../src/protocol/protocol.ts';

// ---------------------------------------------------------------------------
// The slice of the pi extension API the bridge uses
// ---------------------------------------------------------------------------

/** A registered pi event handler. Pi passes `(event, ctx)`. */
export type BridgeHandler = (event: any, ctx: BridgeCtx) => unknown;

/** The read-only session manager methods the bridge reads identity from. */
export interface BridgeSessionManager {
  getSessionId(): string;
  getSessionFile(): string | undefined;
  getEntries(): unknown[];
}

/** The extension context, narrowed to what the bridge reads. */
export interface BridgeCtx {
  mode: string;
  cwd: string;
  model?: { id: string } | undefined;
  thinkingLevel?: string | undefined;
  sessionManager: BridgeSessionManager;
  abort(): void;
  compact(options?: unknown): void;
}

/** The extension API, narrowed to what the bridge calls. */
export interface BridgePi {
  on(event: string, handler: BridgeHandler): () => void;
  sendUserMessage(
    content: string,
    options?: { deliverAs?: 'steer' | 'followUp'; expandPromptTemplates?: boolean },
  ): void;
  setModel(model: unknown): Promise<boolean>;
  setThinkingLevel(level: string): void;
  setSessionName(name: string): void;
  getSessionName?(): string | undefined;
}

// ---------------------------------------------------------------------------
// AssistantMessageEvent (transcribed from pi-ai/dist/types.d.ts)
// ---------------------------------------------------------------------------

/** The real `AssistantMessageEvent` variants, with payloads narrowed to `unknown`. */
export type AssistantMessageEvent =
  | { type: 'start'; partial: unknown }
  | { type: 'text_start'; contentIndex: number; partial: unknown }
  | { type: 'text_delta'; contentIndex: number; delta: string; partial: unknown }
  | { type: 'text_end'; contentIndex: number; content: string; partial: unknown }
  | { type: 'thinking_start'; contentIndex: number; partial: unknown }
  | { type: 'thinking_delta'; contentIndex: number; delta: string; partial: unknown }
  | { type: 'thinking_end'; contentIndex: number; content: string; partial: unknown }
  | { type: 'toolcall_start'; contentIndex: number; partial: unknown }
  | { type: 'toolcall_delta'; contentIndex: number; delta: string; partial: unknown }
  | { type: 'toolcall_end'; contentIndex: number; toolCall: unknown; partial: unknown }
  | { type: 'done'; reason: string; message: unknown }
  | { type: 'error'; reason: string; error: unknown };

/** Either a normalized payload to send, or a stated reason for dropping it. */
export type NormalizedEvent =
  | { kind: 'emit'; payload: EventPayload }
  | { kind: 'ignore'; reason: string };

function errorText(error: unknown): string {
  if (typeof error === 'object' && error !== null) {
    const message = (error as { errorMessage?: unknown }).errorMessage;
    if (typeof message === 'string' && message.length > 0) return message;
  }
  return 'error';
}

/**
 * Bounds an agent-supplied `message` to the shared relay cap. A message that
 * fits is returned untouched; an oversized one (e.g. a `done` carrying base64
 * images) is replaced by a small marker, so it cannot exceed the hub's frame
 * cap and cost the transcript a message.
 */
function boundMessage(
  message: unknown,
  maxBytes: number,
): { message: unknown; truncated: boolean } {
  const serialized = JSON.stringify(message) ?? 'null';
  const bytes = Buffer.byteLength(serialized);
  if (bytes <= maxBytes) return { message, truncated: false };
  return { message: { truncated: true, bytes }, truncated: true };
}

/**
 * Maps one pi assistant-stream event to at most one normalized protocol
 * payload. Total and explicit: every variant either emits or states why it is
 * ignored, and an unrecognized variant is *also* an explicit ignore.
 *
 * Only text deltas stream content; the final `done` message and `error` status
 * are forwarded so the transcript can settle, and `thinking_start` emits a
 * content-free phase frame so the status indicator can say "Thinking…".
 * Thinking and tool-call *deltas* are deliberately not streamed in this
 * milestone.
 */
export function normalizeAssistantEvent(
  event: AssistantMessageEvent,
  seq: number,
): NormalizedEvent {
  switch (event.type) {
    case 'text_delta':
      return { kind: 'emit', payload: { kind: 'stream', seq, text: event.delta } };
    case 'done': {
      // Real pi does NOT forward a `done` assistantMessageEvent on
      // `message_update`; assistant completion arrives as the `message_end`
      // extension event, handled by `normalizeMessageEnd` (the live producer).
      // This branch is retained because `done` is part of the transcribed pi-ai
      // union and the exhaustive switch below depends on it — not because it
      // fires. Do not "fix" it back to being the producer.
      const bounded = boundMessage(event.message, MAX_RELAY_BYTES);
      return {
        kind: 'emit',
        payload: { kind: 'message', message: bounded.message, truncated: bounded.truncated },
      };
    }
    case 'error':
      return {
        kind: 'emit',
        payload: { kind: 'status', event: 'error', message: errorText(event.error) },
      };
    case 'start':
    case 'text_start':
    case 'text_end':
      return { kind: 'ignore', reason: `block-${event.type}` };
    case 'thinking_start':
      // A content-free liveness phase: the block is empty at `*_start` (pi-ai
      // types.d.ts), and reasoning content is never streamed. Only the phase
      // travels, so the app can label "Thinking…" without duplicated bytes.
      return { kind: 'emit', payload: { kind: 'stream', seq, phase: 'thinking' } };
    case 'thinking_delta':
    case 'thinking_end':
      return { kind: 'ignore', reason: 'thinking-not-streamed' };
    case 'toolcall_start':
    case 'toolcall_delta':
    case 'toolcall_end':
      return { kind: 'ignore', reason: 'tool-calls-not-streamed' };
    default: {
      // Compile-time exhaustiveness: a new variant lands here as a type error.
      const unreachable: never = event;
      void unreachable;
      const type = (event as { type?: string }).type ?? 'unknown';
      return { kind: 'ignore', reason: `unknown-assistant-event:${type}` };
    }
  }
}

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/** The pi `message_end` extension event: the authoritative final message. */
export interface MessageEndEvent {
  type: 'message_end';
  message: unknown;
}

/** The roles whose `message_end` is relayed. `user` carries the user's own
 * prompt (M1: own messages in the transcript); `assistant` carries the
 * committed reply. `toolResult` (M2) carries a tool's output and is relayed
 * only now that `deriveBlocks` pairs it into its call and `ToolBlock` renders
 * it — relaying it a milestone earlier would have shipped unlabelled tool
 * noise. `system`/`custom`/unknown stay ignored. */
const RELAYED_MESSAGE_ROLES = new Set(['user', 'assistant', 'toolResult']);

/**
 * Maps pi's `message_end` extension event to at most one normalized payload.
 *
 * This is the live producer of the `message` payload: real pi signals assistant
 * completion with `message_end`, not with a `done` assistantMessageEvent (see
 * the comment on the `done` branch above). `message_end` fires for *every*
 * role — the system prompt, the user's own prompt, tool results — so only a
 * relayed role is sent; every other role is an explicit ignore, never a silent
 * drop.
 */
export function normalizeMessageEnd(event: MessageEndEvent): NormalizedEvent {
  const message = event.message;
  const role =
    typeof message === 'object' && message !== null
      ? (message as { role?: unknown }).role
      : undefined;
  if (typeof role !== 'string' || !RELAYED_MESSAGE_ROLES.has(role)) {
    const label = typeof role === 'string' ? role : 'unknown';
    return { kind: 'ignore', reason: `message-end-unrelayed-role:${label}` };
  }
  const bounded = boundMessage(message, MAX_RELAY_BYTES);
  return {
    kind: 'emit',
    payload: { kind: 'message', message: bounded.message, truncated: bounded.truncated },
  };
}

/** The modes in which the bridge is active; `json`/`print` stay inert. */
const ACTIVE_MODES = new Set(['tui', 'rpc']);

export function isActiveMode(mode: string): boolean {
  return ACTIVE_MODES.has(mode);
}

/** The bridge's command allowlist. Anything else — including a case- or
 * whitespace-variant of an entry — is refused, because the match is exact. */
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

const BACKOFF_BASE_MS = 500;
const BACKOFF_CAP_MS = 30_000;
/**
 * The fixed wait after a `4008` (rate-limited) close: the hub deliberately
 * delays that close, so retrying sooner would only add load. Longer than the
 * first backoff step by construction.
 */
export const RATE_LIMITED_RECONNECT_MS = 30_000;

export interface BackoffOptions {
  rng?: () => number;
}

/** Exponential backoff with full jitter, capped. `attempt` is 0-based. */
export function computeBackoff(attempt: number, options: BackoffOptions = {}): number {
  const rng = options.rng ?? Math.random;
  const ceiling = Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * 2 ** Math.max(0, attempt));
  return Math.floor(rng() * ceiling);
}

export interface HistoryProjection {
  entries: unknown[];
  truncated: boolean;
}

/**
 * Prefix-projects transcript entries to a byte cap. Stops at the first entry
 * that would overflow and flags the result, so a viewer can tell it is partial
 * rather than silently short.
 */
export function projectHistory(entries: readonly unknown[], maxBytes: number): HistoryProjection {
  const kept: unknown[] = [];
  let bytes = 2; // the enclosing `[]`
  for (const entry of entries) {
    const serialized = JSON.stringify(entry) ?? 'null';
    const size = Buffer.byteLength(serialized) + (kept.length > 0 ? 1 : 0);
    if (bytes + size > maxBytes) {
      return { entries: kept, truncated: true };
    }
    bytes += size;
    kept.push(entry);
  }
  return { entries: kept, truncated: false };
}

// ---------------------------------------------------------------------------
// Session labels
// ---------------------------------------------------------------------------

/** The label's cap in Unicode code points, not UTF-16 units, so truncation
 * never leaves a lone surrogate. */
export const LABEL_MAX_CODE_POINTS = 80;

/**
 * Extracts the text of a pi message content value: a string verbatim, or the
 * joined `text` of its `{type:'text'}` parts. An image (or any other) part
 * contributes nothing; an unrecognized shape is empty text.
 */
function messageText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .map((part) => {
      if (typeof part !== 'object' || part === null) return '';
      const candidate = part as { type?: unknown; text?: unknown };
      return candidate.type === 'text' && typeof candidate.text === 'string'
        ? candidate.text
        : '';
    })
    .join(' ');
}

/**
 * Trims a raw label to a single sanitized line of at most
 * `LABEL_MAX_CODE_POINTS` code points, or `null` when there is nothing usable.
 * Control characters (including newlines) collapse to spaces, mirroring pi's
 * own session-selector sanitizer; the code-point truncation never splits a
 * surrogate pair.
 */
export function sanitizeLabel(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  if (cleaned.length === 0) return null;
  return Array.from(cleaned).slice(0, LABEL_MAX_CODE_POINTS).join('');
}

/** The label a single transcript entry contributes: a user message's text, or
 * `null` for any other role (and for an image-only user message). */
export function labelFromMessage(message: unknown): string | null {
  if (typeof message !== 'object' || message === null) return null;
  const candidate = message as { role?: unknown; content?: unknown };
  if (candidate.role !== 'user') return null;
  return sanitizeLabel(messageText(candidate.content));
}

/**
 * The last user prompt among transcript entries, or `null`.
 *
 * REGISTER/RECONNECT-TIME ONLY. Real pi persists a message with
 * `sessionManager.appendMessage` *after* it awaits the `message_end` extension
 * event (`agent-session.js`), so a scan of entries during a live turn is stale
 * by one prompt. The live path reads the event's own message
 * (`labelFromMessage`), never this.
 */
export function labelFromEntries(entries: readonly unknown[]): string | null {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (typeof entry !== 'object' || entry === null) continue;
    const label = labelFromMessage((entry as { message?: unknown }).message);
    if (label !== null) return label;
  }
  return null;
}

export interface BridgeEndpoint {
  url: string;
  token: string;
}

export interface EndpointDirs {
  runtimeDir?: string;
  configDir?: string;
}

/** Resolves the hub's loopback URL from discovery and the token from config. */
export function readEndpoint(dirs: EndpointDirs = {}): BridgeEndpoint | null {
  const record = readDiscovery(dirs.runtimeDir ?? resolveRuntimeDir());
  if (record === null) return null;
  let token: string;
  try {
    token = loadOrCreateToken(dirs.configDir ?? resolveConfigDir()).token;
  } catch {
    return null;
  }
  return { url: `ws://127.0.0.1:${record.agentPort}`, token };
}

// ---------------------------------------------------------------------------
// Injectable seams
// ---------------------------------------------------------------------------

/** The `close` event fields the bridge reads; the code drives reconnect policy. */
export interface BridgeCloseEvent {
  readonly code?: number;
  readonly reason?: string;
}

/** The slice of the WHATWG WebSocket the bridge uses. */
export interface BridgeSocket {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  addEventListener(type: 'close', handler: (event: BridgeCloseEvent) => void): void;
  addEventListener(type: string, handler: (event: unknown) => void): void;
}

export type SocketFactory = (url: string) => BridgeSocket;

export interface BridgeDeps {
  env?: NodeJS.ProcessEnv;
  socketFactory?: SocketFactory;
  resolveEndpoint?: () => BridgeEndpoint | null;
  write?: (stream: 'stderr', text: string) => void;
  rng?: () => number;
  setTimeout?: (fn: () => void, ms: number) => unknown;
  clearTimeout?: (handle: unknown) => void;
}

interface ResolvedDeps {
  env: NodeJS.ProcessEnv;
  socketFactory: SocketFactory;
  resolveEndpoint: () => BridgeEndpoint | null;
  write: (stream: 'stderr', text: string) => void;
  rng: () => number;
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (handle: unknown) => void;
}

const SOCKET_OPEN = 1;

function resolveDeps(deps: BridgeDeps): ResolvedDeps {
  return {
    env: deps.env ?? process.env,
    // Native WebSocket only — no `ws` in the extension.
    socketFactory: deps.socketFactory ?? ((url) => new WebSocket(url) as unknown as BridgeSocket),
    resolveEndpoint: deps.resolveEndpoint ?? (() => readEndpoint()),
    write: deps.write ?? ((_stream, text) => process.stderr.write(text)),
    rng: deps.rng ?? Math.random,
    setTimeout: deps.setTimeout ?? ((fn, ms) => setTimeout(fn, ms)),
    clearTimeout: deps.clearTimeout ?? ((handle) => clearTimeout(handle as NodeJS.Timeout)),
  };
}

// ---------------------------------------------------------------------------
// Wire helpers
// ---------------------------------------------------------------------------

function encodeAgentMessage(message: AgentToHubMessage): string {
  // `encode` is the protocol module's single-object encoder for the message
  // types it fully owns (hello/event); the rest are typed by protocol.ts too.
  if (message.type === 'hello' || message.type === 'event') return encode(message);
  return JSON.stringify(message);
}

function parseCommand(message: Record<string, unknown>): CommandMessage | null {
  const id = asString(message.id);
  const sessionId = asString(message.sessionId);
  const name = asString(message.name);
  if (id === null || sessionId === null || name === null) return null;
  const command: CommandMessage = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId,
    name,
  };
  if ('args' in message) command.args = message.args;
  return command;
}

// ---------------------------------------------------------------------------
// The bridge
// ---------------------------------------------------------------------------

interface CommandOutcome {
  ok: boolean;
  error?: string;
}

class Bridge {
  private readonly pi: BridgePi;
  private readonly deps: ResolvedDeps;
  private readonly debug: (stream: 'stderr', text: string) => void;
  private socket: BridgeSocket | null = null;
  private ctx: BridgeCtx | null = null;
  private seq = 0;
  private lastLabel: string | null = null;
  private state: AgentState = 'idle';
  private attempt = 0;
  private reconnectTimer: unknown = null;
  private closed = false;

  constructor(pi: BridgePi, deps: ResolvedDeps) {
    this.pi = pi;
    this.deps = deps;
    this.debug = (stream, text) => {
      if (deps.env.PI_DROID_DEBUG === '1') deps.write(stream, text);
    };
  }

  install(): void {
    // The socket is opened here, in the handler, never in the factory. Every
    // pi callback is guarded so an exception cannot escape into pi (which would
    // print to stderr and take the session down).
    this.pi.on('session_start', (_event, ctx) => this.guard(() => this.onSessionStart(ctx)));
    this.pi.on('session_shutdown', () => this.guard(() => this.onSessionShutdown()));
    this.pi.on('message_update', (event) => this.guard(() => this.onMessageUpdate(event)));
    // Real pi's assistant-completion signal. `message_update` never carries a
    // `done`, so this is the only live source of the `message` payload.
    this.pi.on('message_end', (event) => this.guard(() => this.onMessageEnd(event)));
    // `/session-name` in the TUI emits `session_info_changed`; subscribing keeps
    // the phone's label current without waiting for the next prompt.
    this.pi.on('session_info_changed', () =>
      this.guard(() => this.refreshLabel(this.currentLabel())),
    );
    this.pi.on('agent_start', () => this.guard(() => this.setAgentState('running')));
    // Terminal state is `agent_settled`, deliberately not `agent_end`.
    this.pi.on('agent_settled', () => this.guard(() => this.setAgentState('settled')));
  }

  /**
   * Runs a callback so nothing can escape into pi or the WebSocket event loop.
   * A socket callback that throws is an uncaught exception: Node prints to
   * stderr and pi dies, which breaks the absolute silence guarantee. Failures
   * are surfaced only under debug.
   */
  private guard(run: () => void): void {
    try {
      run();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.debug('stderr', `pi-droid bridge: handler failed: ${message}\n`);
    }
  }

  private onSessionStart(ctx: BridgeCtx): void {
    // Session replacement invalidates the previous context: drop the old
    // socket and every session-scoped value before binding the new context.
    this.closeSocket('session replaced');
    this.cancelReconnect();
    this.ctx = ctx;
    this.closed = false;
    this.seq = 0;
    this.state = 'idle';
    this.attempt = 0;
    if (!isActiveMode(ctx.mode)) {
      this.debug('stderr', `pi-droid bridge: inert in ${ctx.mode} mode\n`);
      return;
    }
    this.openSocket();
  }

  private onSessionShutdown(): void {
    this.closed = true;
    this.ctx = null;
    this.cancelReconnect();
    this.closeSocket('shutdown');
  }

  private closeSocket(reason: string): void {
    const socket = this.socket;
    this.socket = null;
    if (socket === null) return;
    try {
      socket.close(1000, reason);
    } catch {
      // Already closed; nothing to do.
    }
  }

  private cancelReconnect(): void {
    if (this.reconnectTimer === null) return;
    this.deps.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
  }

  private openSocket(): void {
    const endpoint = this.deps.resolveEndpoint();
    if (endpoint === null) {
      this.debug('stderr', 'pi-droid bridge: no hub discovered\n');
      this.scheduleReconnect();
      return;
    }
    const socket = this.deps.socketFactory(endpoint.url);
    this.socket = socket;
    socket.addEventListener('open', () =>
      this.guard(() => {
        if (this.socket !== socket) return;
        this.attempt = 0;
        this.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: endpoint.token });
        this.sendRegister(this.currentLabel());
        this.sendAgentState();
      }),
    );
    socket.addEventListener('message', (event) => this.guard(() => this.onMessage(event)));
    socket.addEventListener('error', () =>
      this.guard(() => this.debug('stderr', 'pi-droid bridge: socket error\n')),
    );
    socket.addEventListener('close', (event) => this.guard(() => this.onSocketClose(socket, event)));
  }

  private onSocketClose(socket: BridgeSocket, event: BridgeCloseEvent): void {
    if (this.socket !== socket) return;
    this.socket = null;
    const code = event.code;
    this.debug('stderr', `pi-droid bridge: socket closed (${String(code ?? 'transport')})\n`);
    // 4003 is a capability violation: a bridge bug, not a transient failure.
    // Retrying it at capped backoff would reconnect forever.
    if (code === 4003) return;
    // 4008 is rate-limited: the hub delayed the close deliberately, so wait a
    // longer fixed span rather than an ordinary jittered backoff step.
    if (code === 4008) {
      this.scheduleReconnect(RATE_LIMITED_RECONNECT_MS);
      return;
    }
    this.scheduleReconnect();
  }

  private scheduleReconnect(fixedDelayMs?: number): void {
    if (this.closed) return;
    // A pending timer already owns the next dial; scheduling a second would
    // leak the first and double-connect.
    if (this.reconnectTimer !== null) return;
    const delay = fixedDelayMs ?? computeBackoff(this.attempt, { rng: this.deps.rng });
    if (fixedDelayMs === undefined) this.attempt += 1;
    this.reconnectTimer = this.deps.setTimeout(() => {
      this.reconnectTimer = null;
      this.openSocket();
    }, delay);
  }

  private send(message: AgentToHubMessage): void {
    if (this.socket === null || this.socket.readyState !== SOCKET_OPEN) return;
    this.socket.send(encodeAgentMessage(message));
  }

  private sendEvent(payload: EventPayload): void {
    const message: EventMessage = { protocolVersion: PROTOCOL_VERSION, type: 'event', payload };
    this.send(message);
  }

  private sendRegister(label: string | null): void {
    const ctx = this.ctx;
    if (ctx === null) return;
    const manager = ctx.sessionManager;
    const message: RegisterMessage = {
      protocolVersion: PROTOCOL_VERSION,
      type: 'register',
      sessionId: manager.getSessionId(),
      sessionFile: manager.getSessionFile(),
      cwd: ctx.cwd,
      mode: ctx.mode,
      pid: process.pid,
    };
    if (ctx.model !== undefined) message.model = ctx.model.id;
    if (ctx.thinkingLevel !== undefined) message.thinkingLevel = ctx.thinkingLevel;
    if (label !== null) message.name = label;
    this.lastLabel = label;
    this.send(message);
  }

  /**
   * The session's label: pi's explicit name, else the caller's fallback
   * (entries at register, the event's own message live). One try/catch covers
   * both reads so a throwing `getSessionName` or `getEntries` degrades to "no
   * label" — the hub's basename fallback — rather than costing registration.
   */
  private resolveLabel(fallback: () => string | null): string | null {
    try {
      return sanitizeLabel(this.pi.getSessionName?.()) ?? fallback();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.debug('stderr', `pi-droid bridge: label resolution failed: ${message}\n`);
      return null;
    }
  }

  private currentLabel(): string | null {
    const ctx = this.ctx;
    if (ctx === null) return null;
    return this.resolveLabel(() => labelFromEntries(ctx.sessionManager.getEntries()));
  }

  private refreshLabel(label: string | null): void {
    if (label === null || label === this.lastLabel) return;
    this.sendRegister(label);
  }

  private sendAgentState(): void {
    this.sendEvent({ kind: 'agent', state: this.state });
  }

  private setAgentState(state: AgentState): void {
    this.state = state;
    this.sendEvent({ kind: 'agent', state });
  }

  private onMessageUpdate(event: unknown): void {
    const assistantEvent = (event as { assistantMessageEvent?: AssistantMessageEvent })
      .assistantMessageEvent;
    if (assistantEvent === undefined) return;
    const candidate = this.seq + 1;
    const normalized = normalizeAssistantEvent(assistantEvent, candidate);
    if (normalized.kind === 'ignore') return;
    if (normalized.payload.kind === 'stream') this.seq = candidate;
    this.sendEvent(normalized.payload);
  }

  private onMessageEnd(event: unknown): void {
    const normalized = normalizeMessageEnd(event as MessageEndEvent);
    if (normalized.kind === 'ignore') return;
    this.sendEvent(normalized.payload);
    // The live path uses the event's own message, never the entries scan: pi
    // persists the message only after this event, so `getEntries()` is stale.
    this.refreshLabel(
      this.resolveLabel(() => labelFromMessage((event as { message?: unknown }).message)),
    );
  }

  private onMessage(event: unknown): void {
    const data = (event as { data?: unknown }).data;
    if (typeof data !== 'string') return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(data);
    } catch {
      return;
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return;
    const message = parsed as Record<string, unknown>;
    if (message.protocolVersion !== PROTOCOL_VERSION) return;
    if (message.type === 'command') this.onCommand(message);
    else if (message.type === 'history-request') this.sendHistory();
  }

  private onCommand(message: Record<string, unknown>): void {
    const command = parseCommand(message);
    if (command === null) return;
    void this.dispatch(command);
  }

  private async dispatch(command: CommandMessage): Promise<void> {
    try {
      if (!COMMAND_ALLOWLIST.has(command.name)) {
        this.sendCommandResult(command.id, false, 'command not allowed');
        return;
      }
      const ctx = this.ctx;
      if (ctx === null) {
        this.sendCommandResult(command.id, false, 'no active session');
        return;
      }
      // Re-checked here so a future socket path cannot dispatch in an inert
      // mode, and the session is verified rather than trusted to hub routing.
      if (!isActiveMode(ctx.mode)) {
        this.sendCommandResult(command.id, false, 'bridge inactive in this mode');
        return;
      }
      if (command.sessionId !== ctx.sessionManager.getSessionId()) {
        this.sendCommandResult(command.id, false, 'session mismatch');
        return;
      }
      if (command.name === 'fetchHistory') {
        this.sendHistory();
        this.sendCommandResult(command.id, true);
        return;
      }
      const outcome = await this.dispatchCommand(ctx, command.name, command.args);
      this.sendCommandResult(command.id, outcome.ok, outcome.error);
    } catch (error) {
      this.sendCommandResult(
        command.id,
        false,
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  private async dispatchCommand(
    ctx: BridgeCtx,
    name: string,
    args: unknown,
  ): Promise<CommandOutcome> {
    const fields = asObject(args) ?? {};
    switch (name) {
      case 'prompt':
      case 'steer':
      case 'followup': {
        const text = asString(fields.text);
        if (text === null) return { ok: false, error: 'missing text' };
        // `prompt` is plain; `steer` and `followup` queue during streaming.
        const deliverAs = name === 'steer' ? 'steer' : name === 'followup' ? 'followUp' : undefined;
        this.pi.sendUserMessage(text, deliverAs === undefined ? {} : { deliverAs });
        return { ok: true };
      }
      case 'abort':
        ctx.abort();
        return { ok: true };
      case 'setModel': {
        if (fields.model === undefined) return { ok: false, error: 'missing model' };
        const accepted = await this.pi.setModel(fields.model);
        return accepted ? { ok: true } : { ok: false, error: 'model not accepted' };
      }
      case 'setThinkingLevel': {
        const level = asString(fields.level);
        if (level === null) return { ok: false, error: 'missing level' };
        this.pi.setThinkingLevel(level);
        return { ok: true };
      }
      case 'compact':
        ctx.compact();
        return { ok: true };
      case 'setSessionName': {
        const sessionName = asString(fields.name);
        if (sessionName === null) return { ok: false, error: 'missing name' };
        this.pi.setSessionName(sessionName);
        // Read the (possibly normalized) name back: a rename is a label change
        // even when it was made elsewhere.
        this.refreshLabel(this.currentLabel());
        return { ok: true };
      }
      default:
        return { ok: false, error: 'command not allowed' };
    }
  }

  private sendHistory(): void {
    const ctx = this.ctx;
    if (ctx === null) return;
    const projection = projectHistory(ctx.sessionManager.getEntries(), MAX_RELAY_BYTES);
    const message: HistoryMessage = {
      protocolVersion: PROTOCOL_VERSION,
      type: 'history',
      sessionId: ctx.sessionManager.getSessionId(),
      entries: projection.entries,
      truncated: projection.truncated,
    };
    this.send(message);
  }

  private sendCommandResult(id: string, ok: boolean, error?: string): void {
    const message: CommandResultMessage = {
      protocolVersion: PROTOCOL_VERSION,
      type: 'command-result',
      id,
      ok,
    };
    if (error !== undefined) message.error = error;
    this.send(message);
  }
}

/**
 * Installs the bridge on a pi `ExtensionAPI`. Side-effectful by design: it
 * registers handlers and returns nothing. Tests call this directly with
 * injected dependencies; pi calls the default export with its own API.
 */
export function installBridge(pi: BridgePi, deps: BridgeDeps = {}): void {
  new Bridge(pi, resolveDeps(deps)).install();
}

/** The extension entry point pi loads. */
export default function piDroidBridge(pi: BridgePi): void {
  installBridge(pi);
}
