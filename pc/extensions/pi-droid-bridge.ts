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
  HISTORY_MAX_BYTES,
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
  SlashCommand,
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
  /**
   * Whether the session is idle (`!streaming && !compacting`).
   *
   * Required, unlike `getContextUsage` below. The bridge picks the delivery
   * mode from it, and a silent fallback (`ctx.isIdle?.() ?? true`) would
   * reproduce the exact silent mid-turn drop this method exists to fix. On an
   * older pi that lacks it the call throws into `dispatch`'s catch, yielding a
   * loud `command-result ok:false`, and `tsc` rejects any ctx stub that omits
   * it.
   */
  isIdle(): boolean;
  /**
   * pi's context-usage estimate. Optional because the bridge's pi slice is
   * structural: an older pi without it degrades to "no label" rather than a
   * crash. Returns undefined when there is no model, or no known window.
   */
  getContextUsage?():
    | { tokens: number | null; contextWindow: number }
    | undefined;
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
  /**
   * pi's own slash-command list for the active session. Optional because the
   * bridge's pi slice is structural: an older pi without it degrades to an
   * `ok:false` result rather than a crash.
   */
  getCommands?(): SlashCommand[];
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
 * Text and reasoning deltas stream content; the final `done` message and `error`
 * status are forwarded so the transcript can settle, and `thinking_start` emits a
 * content-free phase frame so the status indicator can say "Thinking…" before the
 * first reasoning chunk lands. Tool-call deltas are deliberately not streamed:
 * the call arrives whole in the committed message.
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
      // types.d.ts). The reasoning text follows as `thinking_delta` frames, each
      // carrying one chunk in `text` with the same phase.
      return { kind: 'emit', payload: { kind: 'stream', seq, phase: 'thinking' } };
    case 'thinking_delta':
      // Reasoning streams like answer text, tagged so the app routes it to its
      // own buffer instead of the reply. `thinking_start` still arrives first
      // as a content-free liveness frame, so a slow first token is never
      // mislabelled.
      return {
        kind: 'emit',
        payload: { kind: 'stream', seq, text: event.delta, phase: 'thinking' },
      };
    case 'thinking_end':
      // Deliberately ignored, and NOT a silent drop: `thinking_end` carries the
      // whole text of one thinking block, so emitting it would make a second
      // producer of text the deltas already streamed. The committed assistant
      // message arrives immediately after and is authoritative.
      return { kind: 'ignore', reason: 'thinking-end-committed-message-authoritative' };
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
 * whitespace-variant of an entry — is refused, because the match is exact.
 * Exported so a test can pin it equal to the hub's copy: the two must not
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
 * The most recent entries that fit in `maxBytes`, in chronological order.
 *
 * A *suffix* window, not a prefix. This frame is replayed to a viewer on every
 * subscribe/reconnect, so the newest entries are the ones that must survive:
 * a prefix window drops exactly the recent turns the viewer is looking for,
 * which reads on the phone as "the session ends at some old message" even
 * though live events keep arriving. Walking backwards and reversing keeps the
 * kept run contiguous and chronological. `truncated` means the *older* entries
 * were omitted.
 */
export function projectHistory(entries: readonly unknown[], maxBytes: number): HistoryProjection {
  const kept: unknown[] = [];
  let bytes = 2; // the enclosing `[]`
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    const serialized = JSON.stringify(entry) ?? 'null';
    let size = Buffer.byteLength(serialized) + (kept.length > 0 ? 1 : 0);
    let value = entry;
    if (size > maxBytes) {
      // An entry no window could ever hold (a 1.4 MB tool result is real here)
      // would otherwise be a hard wall: it stops the walk and leaves most of
      // the budget unspent, so everything older becomes unreachable. Collapse
      // it to the marker the app already renders as a notice, which keeps the
      // walk honest — a named gap, not a silent one.
      value = { truncated: true, bytes: Buffer.byteLength(serialized) };
      size = Buffer.byteLength(JSON.stringify(value)) + (kept.length > 0 ? 1 : 0);
    }
    if (bytes + size > maxBytes) break;
    bytes += size;
    kept.push(value);
  }
  kept.reverse();
  return { entries: kept, truncated: kept.length < entries.length };
}

/**
 * pi's own context-usage reading, if the host exposes one and has a model with a
 * known window. Deliberately not a passthrough of the whole object: only the two
 * numbers the app renders travel, so a field added to pi's `ContextUsage` later
 * cannot change the wire by accident.
 *
 * Structural on purpose — an older pi has no such method, and that must be a
 * missing label rather than a crash.
 */
function readContextUsage(
  ctx: BridgeCtx,
): { tokens: number | null; contextWindow: number } | null {
  const usage = ctx.getContextUsage?.();
  if (usage === undefined) return null;
  return { tokens: usage.tokens, contextWindow: usage.contextWindow };
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
 * The snippet cap in Unicode code points, not UTF-16 units, so a slice never
 * leaves a lone surrogate. Deliberately the wire cap, larger than the app's
 * visible cap (140); keep that ordering if either changes.
 */
export const SETTLED_TEXT_MAX_CODE_POINTS = 200;

/**
 * Bounds a turn's final assistant text to `maxCodePoints` code points for a
 * notification body. Text that fits is returned untouched; a longer string is
 * sliced and flagged `truncated`.
 */
export function settleText(
  text: string,
  maxCodePoints: number,
): { text: string; truncated: boolean } {
  const points = Array.from(text);
  if (points.length <= maxCodePoints) return { text, truncated: false };
  return { text: points.slice(0, maxCodePoints).join(''), truncated: true };
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
  commands?: SlashCommand[];
  queued?: boolean;
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
  /** The current turn's final assistant snippet, reset at each turn start. */
  private lastSettled: { text: string; truncated: boolean } = { text: '', truncated: false };
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
    this.pi.on('agent_start', () =>
      this.guard(() => {
        // A new turn starts with no reply, so a settle before any assistant
        // message cannot inherit the previous turn's text.
        this.lastSettled = { text: '', truncated: false };
        this.setAgentState('running');
      }),
    );
    // Terminal state is `agent_settled`, deliberately not `agent_end`.
    this.pi.on('agent_settled', () =>
      this.guard(() => {
        this.setAgentState('settled');
        this.sendUsageEvent();
        this.sendSettleEvent();
      }),
    );
    // Compaction is an LLM summarization call, so without this the app sits
    // silent from the tap until it finishes. `session_before_compact` is the
    // only extension-visible "starting" signal: pi emits it ahead of the
    // summarization call from BOTH entry points, for all three reasons (manual,
    // threshold, overflow) — so an automatic compaction is announced too.
    // Registering a handler makes pi await it, so it stays cheap and returns
    // undefined, which pi reads as "no cancel, no custom compaction".
    this.pi.on('session_before_compact', () =>
      this.guard(() => this.sendCompactingEvent(true)),
    );
    // Compaction invalidates the token count — pi reports it as unknown until the
    // next model response — so the reading is re-taken rather than left stale.
    // Clearing the indicator in the same handler keeps the two from overlapping.
    this.pi.on('session_compact', () =>
      this.guard(() => {
        this.sendCompactingEvent(false);
        this.sendUsageEvent();
      }),
    );
    // Any effective thinking-level change: the app's own `setThinkingLevel`, a
    // PC-side `/thinking`, or a clamp during `setModel`. Re-reporting usage keeps
    // the level the menu shows current without waiting for the next turn.
    this.pi.on('thinking_level_select', () => this.guard(() => this.sendUsageEvent()));
    // `ctx.compact()` is fire-and-forget and passes no `onError`, so a failed
    // compaction is otherwise invisible. Surface every reason (manual, overflow,
    // threshold) — an auto-compaction failure is more consequential, not less.
    // pi emits this from the `catch` of both compaction paths, so the indicator
    // raised above is always cleared — including when the compaction was aborted
    // rather than failed.
    this.pi.on('session_compact_failed', (event) =>
      this.guard(() => {
        this.sendCompactingEvent(false);
        this.onCompactFailed(event);
      }),
    );
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
    this.lastSettled = { text: '', truncated: false };
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
    // The snippet comes from the ORIGINAL message, never the bounded payload:
    // an oversized reply is replaced by a `{truncated:true,bytes}` marker, and
    // caching that marker would make every huge reply notify `'No reply'`.
    const original = (event as { message?: unknown }).message;
    if (
      typeof original === 'object' &&
      original !== null &&
      (original as { role?: unknown }).role === 'assistant'
    ) {
      this.lastSettled = settleText(
        messageText((original as { content?: unknown }).content),
        SETTLED_TEXT_MAX_CODE_POINTS,
      );
    }
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
      this.sendCommandResult(
        command.id,
        outcome.ok,
        outcome.error,
        outcome.commands,
        outcome.queued,
      );
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
        // `steer` and `followup` name their mode explicitly. For a plain
        // `prompt` the mode is the agent's: the app cannot make this call well
        // because its agent state is a network round-trip stale, so a stale
        // "idle" would reproduce the silent mid-turn drop. Read `isIdle()`
        // here instead: idle → today's plain prompt; running → steer, mirroring
        // the TUI's Enter (interactive-mode.js:2615). The check is once, at
        // dispatch: pi re-reads `isStreaming` after its own preflight, so the
        // guarantee is "never worse than today", not race-free. Steer-on-idle
        // is benign — pi ignores `streamingBehavior` when not streaming.
        let deliverAs: 'steer' | 'followUp' | undefined;
        // Only the automatic branch reports `queued`: explicit `steer`/`followup`
        // name their mode, so they are not the bridge deciding to queue a plain
        // prompt mid-turn. `false` is never emitted — absent is the default.
        let queued = false;
        if (name === 'steer') {
          deliverAs = 'steer';
        } else if (name === 'followup') {
          deliverAs = 'followUp';
        } else {
          deliverAs = ctx.isIdle() ? undefined : 'steer';
          queued = deliverAs === 'steer';
        }
        // `expandPromptTemplates` is what makes `/name` a command. pi's
        // extension API defaults it to FALSE, which injects the text verbatim
        // and leaves the model to read a command name as prose; pi's own
        // interactive path defaults it to true. Opting in is also what expands
        // `/skill:name`, and matches pi's steer, which expands templates too.
        this.pi.sendUserMessage(text, {
          expandPromptTemplates: true,
          ...(deliverAs === undefined ? {} : { deliverAs }),
        });
        return queued ? { ok: true, queued: true } : { ok: true };
      }
      case 'abort':
        ctx.abort();
        return { ok: true };
      case 'setModel': {
        if (fields.model === undefined) return { ok: false, error: 'missing model' };
        const accepted = await this.pi.setModel(fields.model);
        // The window belongs to the model, so an accepted switch changes the
        // denominator; a refusal changes nothing.
        if (accepted) this.sendUsageEvent();
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
      case 'listCommands': {
        const raw = this.pi.getCommands?.();
        if (raw === undefined || !Array.isArray(raw)) {
          return { ok: false, error: 'commands unavailable' };
        }
        const commands: SlashCommand[] = [];
        for (const entry of raw) {
          const name = asString((entry as { name?: unknown })?.name);
          if (name === null) continue;
          const command: SlashCommand = { name };
          const description = asString((entry as { description?: unknown })?.description);
          if (description !== null) command.description = description;
          commands.push(command);
        }
        return { ok: true, commands };
      }
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
    const projection = projectHistory(ctx.sessionManager.getEntries(), HISTORY_MAX_BYTES);
    const message: HistoryMessage = {
      protocolVersion: PROTOCOL_VERSION,
      type: 'history',
      sessionId: ctx.sessionManager.getSessionId(),
      entries: projection.entries,
      truncated: projection.truncated,
    };
    this.send(message);
    // After the history frame, so a viewer that re-baselines on the snapshot
    // cannot overwrite the fresh reading with an older one. A phone attaching
    // mid-session lands here, which is why the reading rides the replay rather
    // than the register frame: at register the hub has no subscribers yet.
    this.sendUsageEvent();
  }

  /**
   * Sends the current context usage, if pi can report one. A missing reading is
   * silence, never an error: this is ambient information, and it must not be
   * able to break the transcript it decorates.
   */
  private sendUsageEvent(): void {
    const ctx = this.ctx;
    if (ctx === null) return;
    let usage: { tokens: number | null; contextWindow: number } | null;
    try {
      usage = readContextUsage(ctx);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.debug('stderr', `pi-droid bridge: context usage failed: ${message}\n`);
      return;
    }
    if (usage === null) return;
    const level = ctx.thinkingLevel;
    if (typeof level === 'string') {
      this.sendEvent({
        kind: 'usage',
        tokens: usage.tokens,
        contextWindow: usage.contextWindow,
        thinkingLevel: level,
      });
      return;
    }
    this.sendEvent({ kind: 'usage', tokens: usage.tokens, contextWindow: usage.contextWindow });
  }

  /**
   * Announces that a compaction is running, so the app can show it rather than
   * sitting silent through a summarization call.
   *
   * Rides a `status` payload — an existing kind, so no new frame type and no hub
   * restart. This is the one status the app reads as transient state rather than
   * as a transcript notice, so it deliberately carries no `message`: a notice is
   * a row, and a row would outlive the compaction it describes.
   *
   * Paired by construction: every `session_before_compact` is followed by
   * exactly one of `session_compact` or `session_compact_failed`, and both
   * clear it. A hard-killed pi is the one way to leave it stuck. The one
   * theoretical hole is that pi gates the success emit on re-finding the
   * compaction entry it just appended, so a missed lookup would return success
   * having emitted neither — unreachable in practice, recorded so it is not
   * mistaken for a bug if it ever shows up.
   */
  private sendCompactingEvent(active: boolean): void {
    this.sendEvent({ kind: 'status', event: 'compacting', active });
  }

  /**
   * Surfaces a failed compaction as an error notice. Gated on a non-empty
   * `errorMessage`, which also excludes a deliberately aborted compaction (pi
   * leaves `errorMessage` undefined for those). No `reason` filter: manual,
   * overflow and threshold failures are all reported.
   */
  private onCompactFailed(event: unknown): void {
    const errorMessage =
      typeof event === 'object' && event !== null
        ? (event as { errorMessage?: unknown }).errorMessage
        : undefined;
    if (typeof errorMessage !== 'string' || errorMessage.length === 0) return;
    this.sendEvent({ kind: 'status', event: 'error', message: errorMessage });
  }

  /** Emits the cached turn snippet, after the terminal state and usage. */
  private sendSettleEvent(): void {
    this.sendEvent({
      kind: 'settled',
      text: this.lastSettled.text,
      truncated: this.lastSettled.truncated,
    });
  }

  private sendCommandResult(
    id: string,
    ok: boolean,
    error?: string,
    commands?: SlashCommand[],
    queued?: boolean,
  ): void {
    const message: CommandResultMessage = {
      protocolVersion: PROTOCOL_VERSION,
      type: 'command-result',
      id,
      ok,
    };
    if (error !== undefined) message.error = error;
    if (commands !== undefined) message.commands = commands;
    if (queued !== undefined) message.queued = queued;
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
