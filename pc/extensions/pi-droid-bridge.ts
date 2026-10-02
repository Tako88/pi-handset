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
  TOOL_VIEW_MAX_BYTES,
  asObject,
  asString,
  encode,
} from '../src/protocol/protocol.ts';
import type {
  AgentState,
  AgentToHubMessage,
  CommandMessage,
  CommandResultMessage,
  CommandView,
  ContextUsagePayload,
  DiffLine,
  EventMessage,
  EventPayload,
  FileView,
  GenericView,
  HistoryMessage,
  Match,
  ModelSummary,
  RegisterMessage,
  SlashCommand,
  ToolPayload,
  ToolView,
  TreeNodeSummary,
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
  /** Look up one entry by id; used to validate a `/fork` target. */
  getEntry(id: string): unknown;
  /** pi's session tree, for `/tree`. Optional: absent on an older pi. */
  getTree?(): unknown;
}

/**
 * The command context pi hands a registered command's handler. It is the only
 * surface that exposes the session actions, and pi invalidates it after
 * `newSession`/`fork` — so a handler performs exactly one action and returns.
 */
export interface BridgeCommandCtx {
  newSession(): Promise<{ cancelled: boolean }>;
  fork(entryId: string): Promise<{ cancelled: boolean }>;
  navigateTree(targetId: string): Promise<{ cancelled: boolean }>;
}

/** The options bag pi accepts from `registerCommand`. */
export interface BridgeCommandRegistration {
  description?: string;
  handler: (args: string, ctx: BridgeCommandCtx) => unknown;
}

/** The `{provider, id, name}` slice of a pi `Model` the bridge projects onto the wire. */
export interface BridgeModel {
  id: string;
  provider: string;
  name: string;
}

/** The slice of pi's `ModelRegistry` the bridge reads. Structural, like the rest
 * of the pi slice: `getAvailable()` is the only list source and `find()`
 * resolves a reference to the real `Model` `setModel` needs. */
export interface BridgeModelRegistry {
  getAvailable(): unknown[];
  find(provider: string, modelId: string): unknown;
}

/** The extension context, narrowed to what the bridge reads. */
export interface BridgeCtx {
  mode: string;
  cwd: string;
  model?: BridgeModel | undefined;
  thinkingLevel?: string | undefined;
  /**
   * pi's model registry. Optional because the bridge's pi slice is structural:
   * an older pi without it degrades to an `ok:false` result rather than a
   * crash.
   */
  modelRegistry?: BridgeModelRegistry | undefined;
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
  /**
   * Register a slash command. Optional because the bridge's pi slice is
   * structural: an older pi without it leaves the session actions as prose.
   */
  registerCommand?(name: string, options: BridgeCommandRegistration): void;
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

// ---------------------------------------------------------------------------
// Normalized tool views
// ---------------------------------------------------------------------------

/**
 * The line cap for one tool view, pi parity with `DEFAULT_MAX_LINES` (2000).
 * A second knob beside the byte cap: pi's own tools already cap at this many
 * lines, so the bridge applies the same ceiling before the byte budget when a
 * custom tool returns more.
 */
export const TOOL_VIEW_MAX_LINES = 2000;

/** The raw pieces of one tool result a view is built from. */
export interface ToolViewInput {
  name: string;
  args: Record<string, unknown>;
  /** pi's tool content: a string, or `{type:'text'|'image', …}` parts. */
  content: unknown;
  details: Record<string, unknown> | undefined;
  isError: boolean;
}

/** The joined text of a tool content value; text parts join with a newline
 * (tool output is line-structured, unlike `messageText`'s label join). */
function contentText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  const parts: string[] = [];
  for (const part of content) {
    if (typeof part !== 'object' || part === null) continue;
    const candidate = part as { type?: unknown; text?: unknown };
    if (candidate.type === 'text' && typeof candidate.text === 'string') parts.push(candidate.text);
  }
  return parts.join('\n');
}

/** True when a content value carries an image part (an image read). */
function hasImage(content: unknown): boolean {
  if (!Array.isArray(content)) return false;
  return content.some(
    (part) =>
      typeof part === 'object' && part !== null && (part as { type?: unknown }).type === 'image',
  );
}

/** The first non-empty string among a tool's common target-ish arguments. */
function targetOf(args: Record<string, unknown>): string | undefined {
  for (const key of ['path', 'file', 'command', 'pattern']) {
    const value = args[key];
    if (typeof value === 'string' && value.length > 0) return value;
  }
  return undefined;
}

function positiveInt(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : undefined;
}

/** Parses pi's display-oriented `details.diff` into typed lines. */
function parseDiff(diff: string): DiffLine[] {
  const lines: DiffLine[] = [];
  for (const raw of diff.split('\n')) {
    if (raw === '') continue;
    const kind: DiffLine['kind'] = raw.startsWith('+')
      ? 'add'
      : raw.startsWith('-')
        ? 'del'
        : 'ctx';
    const rest = raw.slice(1);
    const match = /^\s*\d+ ?(.*)$/.exec(rest);
    lines.push({ kind, text: match !== null ? match[1]! : rest.trim() });
  }
  return lines;
}

function genericView(args: Record<string, unknown>): GenericView {
  const view: GenericView = { type: 'generic' };
  const target = targetOf(args);
  if (target !== undefined) view.target = target;
  return view;
}

function editView(input: ToolViewInput): ToolView {
  const diff = input.details?.diff;
  if (typeof diff !== 'string' || diff.length === 0) return genericView(input.args);
  const path = typeof input.args.path === 'string' ? input.args.path : '';
  return { type: 'diff', path, lines: parseDiff(diff) };
}

function writeView(input: ToolViewInput): ToolView {
  const content = input.args.content;
  const path = typeof input.args.path === 'string' ? input.args.path : '';
  if (typeof content !== 'string') return genericView(input.args);
  // Drop one trailing newline so a file ending in `\n` does not gain a phantom
  // empty addition; empty content is a diff with zero lines.
  const body = content.endsWith('\n') ? content.slice(0, -1) : content;
  const lines: DiffLine[] =
    body === '' ? [] : body.split('\n').map((text) => ({ kind: 'add', text }));
  return { type: 'diff', path, lines };
}

function readView(input: ToolViewInput): ToolView {
  const path = typeof input.args.path === 'string' ? input.args.path : '';
  // An image read carries bytes, never a text body to render as a file.
  if (hasImage(input.content)) return { type: 'generic', target: path };
  const text = contentText(input.content);
  const view: FileView = { type: 'file', path, content: text };
  const offset = positiveInt(input.args.offset);
  const limit = positiveInt(input.args.limit);
  // The truncated path names the range in its continuation notice; the
  // user-limit path (`details == undefined`) names it only in input.offset/limit.
  const shown = /\[Showing lines (\d+)-(\d+) of \d+/.exec(text);
  if (shown !== null) {
    view.startLine = Number(shown[1]);
    view.endLine = Number(shown[2]);
  } else if (offset !== undefined || limit !== undefined) {
    const startLine = offset ?? 1;
    view.startLine = startLine;
    if (limit !== undefined) view.endLine = startLine + limit - 1;
  }
  return view;
}

function bashView(input: ToolViewInput): ToolView {
  const command = typeof input.args.command === 'string' ? input.args.command : '';
  const output = contentText(input.content);
  const view: CommandView = { type: 'command', command, output };
  const exited = /Command exited with code (\d+)\s*$/.exec(output);
  if (exited !== null) view.exitCode = Number(exited[1]);
  // pi carries no success code, but an `isError:false` result by definition
  // exited 0. The abort/timeout/terminated texts carry no code and stay
  // undefined, even though the timeout text contains digits.
  else if (!input.isError) view.exitCode = 0;
  return view;
}

function grepView(input: ToolViewInput): ToolView {
  const text = contentText(input.content);
  if (text.trim() === 'No matches found') return { type: 'matches', matches: [] };
  const matches: Match[] = [];
  for (const line of text.split('\n')) {
    // A trailing `[...]` notice block is not a match.
    if (line.length === 0 || /^\[.*\]$/.test(line)) continue;
    const match = /^(.*?):(\d+): ?(.*)$/.exec(line);
    if (match !== null) {
      matches.push({ file: match[1]!, line: Number(match[2]), text: match[3]! });
      continue;
    }
    const context = /^(.*?)-(\d+)- ?(.*)$/.exec(line);
    if (context !== null) {
      matches.push({ file: context[1]!, line: Number(context[2]), text: context[3]! });
    }
  }
  return { type: 'matches', matches };
}

function findView(input: ToolViewInput): ToolView {
  const text = contentText(input.content);
  if (text.trim() === 'No files found matching pattern') return { type: 'matches', matches: [] };
  const matches: Match[] = [];
  for (const line of text.split('\n')) {
    if (line.length === 0 || /^\[.*\]$/.test(line)) continue;
    // find has no line number; a file match is `line 0` with empty text.
    matches.push({ file: line, line: 0, text: '' });
  }
  return { type: 'matches', matches };
}

function lsView(input: ToolViewInput): ToolView {
  const text = contentText(input.content);
  if (text.trim() === '(empty directory)') {
    return { type: 'table', columns: ['name', 'type'], rows: [] };
  }
  const rows: string[][] = [];
  for (const line of text.split('\n')) {
    if (line.length === 0 || /^\[.*\]$/.test(line)) continue;
    const isDirectory = line.endsWith('/');
    rows.push([isDirectory ? line.slice(0, -1) : line, isDirectory ? 'directory' : 'file']);
  }
  return { type: 'table', columns: ['name', 'type'], rows };
}

/**
 * Normalizes one tool result into a discriminated view. Total: an unknown tool
 * name, a malformed payload, or an error on a non-shell tool all fall back to
 * `generic`, never to a partially-parsed view. `bash` is the exception — its
 * failure text *is* the output and its exit code is parsed from that text.
 */
export function buildToolView(input: ToolViewInput): ToolView {
  switch (input.name) {
    case 'edit':
      return input.isError ? genericView(input.args) : editView(input);
    case 'write':
      return input.isError ? genericView(input.args) : writeView(input);
    case 'read':
      return input.isError ? genericView(input.args) : readView(input);
    case 'bash':
      return bashView(input);
    case 'grep':
      return input.isError ? genericView(input.args) : grepView(input);
    case 'find':
      return input.isError ? genericView(input.args) : findView(input);
    case 'ls':
      return input.isError ? genericView(input.args) : lsView(input);
    default:
      return genericView(input.args);
  }
}

/**
 * The running payload(s) an assistant message's tool calls produce. A running
 * frame carries an input-only view: `write` can show its all-addition diff
 * before the result lands; everything else shows its target only.
 */
export function toolCallPayloads(
  message: unknown,
  argsById: Map<string, unknown> = new Map(),
): ToolPayload[] {
  const msg = asObject(message);
  if (msg === null || !Array.isArray(msg.content)) return [];
  const payloads: ToolPayload[] = [];
  for (const part of msg.content) {
    const call = asObject(part);
    if (call === null || call.type !== 'toolCall') continue;
    const id = asString(call.id);
    const name = asString(call.name);
    if (id === null || name === null) continue;
    const rawArgs = argsById.has(id) ? argsById.get(id) : call.arguments;
    const args = asObject(rawArgs) ?? {};
    payloads.push({
      kind: 'tool',
      toolCallId: id,
      name,
      status: 'running',
      view:
        name === 'write'
          ? writeView({ name, args, content: undefined, details: undefined, isError: false })
          : genericView(args),
    });
  }
  return payloads;
}

/**
 * The done/error payload a toolResult message produces, or null when the
 * message lacks the identity fields the payload requires.
 */
export function toolResultPayload(
  message: unknown,
  argsById: Map<string, unknown> = new Map(),
): ToolPayload | null {
  const msg = asObject(message);
  if (msg === null) return null;
  const id = asString(msg.toolCallId);
  const name = asString(msg.toolName);
  if (id === null || name === null) return null;
  const args = asObject(argsById.get(id)) ?? {};
  const isError = msg.isError === true;
  return {
    kind: 'tool',
    toolCallId: id,
    name,
    status: isError ? 'error' : 'done',
    view: buildToolView({
      name,
      args,
      content: msg.content,
      details: asObject(msg.details) ?? undefined,
      isError,
    }),
  };
}

/** Caps a string's lines to `TOOL_VIEW_MAX_LINES`, keeping the head. */
function capStringLines(text: string): string {
  const lines = text.split('\n');
  if (lines.length <= TOOL_VIEW_MAX_LINES) return text;
  return lines.slice(0, TOOL_VIEW_MAX_LINES).join('\n');
}

/**
 * Caps a bulk view's lines to `TOOL_VIEW_MAX_LINES`, keeping the head. Returns
 * `true` when a branch actually sliced, so the caller can set `truncated`.
 */
function trimToLineCap(view: ToolView): boolean {
  switch (view.type) {
    case 'diff':
      if (view.lines.length > TOOL_VIEW_MAX_LINES) {
        view.lines.length = TOOL_VIEW_MAX_LINES;
        return true;
      }
      return false;
    case 'file': {
      const capped = capStringLines(view.content);
      if (capped === view.content) return false;
      view.content = capped;
      return true;
    }
    case 'command': {
      const capped = capStringLines(view.output);
      if (capped === view.output) return false;
      view.output = capped;
      return true;
    }
    case 'matches':
      if (view.matches.length > TOOL_VIEW_MAX_LINES) {
        view.matches.length = TOOL_VIEW_MAX_LINES;
        return true;
      }
      return false;
    case 'table':
      if (view.rows.length > TOOL_VIEW_MAX_LINES) {
        view.rows.length = TOOL_VIEW_MAX_LINES;
        return true;
      }
      return false;
    default:
      return false;
  }
}

/** Drops half of a view's bulk lines from the tail, keeping the head. */
function dropHalfBulk(view: ToolView): boolean {
  switch (view.type) {
    case 'diff':
      if (view.lines.length === 0) return false;
      view.lines.splice(Math.floor(view.lines.length / 2));
      return true;
    case 'file': {
      const lines = view.content.split('\n');
      if (lines.length === 0) return false;
      view.content = lines.slice(0, Math.floor(lines.length / 2)).join('\n');
      return true;
    }
    case 'command': {
      const lines = view.output.split('\n');
      if (lines.length === 0) return false;
      view.output = lines.slice(0, Math.floor(lines.length / 2)).join('\n');
      return true;
    }
    case 'matches':
      if (view.matches.length === 0) return false;
      view.matches.splice(Math.floor(view.matches.length / 2));
      return true;
    case 'table':
      if (view.rows.length === 0) return false;
      view.rows.splice(Math.floor(view.rows.length / 2));
      return true;
    default:
      return false;
  }
}

/**
 * Bounds one tool payload to `TOOL_VIEW_MAX_BYTES`. Bulk lines are dropped from
 * the tail until the serialized payload fits, and `view.truncated` is set so the
 * app can render its explicit marker. A view already under the cap is returned
 * untouched. The cap is a quarter of the relay budget, deliberately: a relayed
 * frame is dropped whole whenever any byte is outstanding on the viewer, so a
 * payload bounded at the budget itself would be dropped under any backlog.
 */
export function boundToolPayload(payload: ToolPayload): ToolPayload {
  const view = payload.view;
  if (view === undefined || view.type === 'generic') return payload;
  if (trimToLineCap(view)) view.truncated = true;
  if (Buffer.byteLength(JSON.stringify(payload)) <= TOOL_VIEW_MAX_BYTES) return payload;
  view.truncated = true;
  for (let guard = 0; guard < 64; guard += 1) {
    if (Buffer.byteLength(JSON.stringify(payload)) <= TOOL_VIEW_MAX_BYTES) break;
    if (!dropHalfBulk(view)) break;
  }
  return payload;
}

/** The pi message inside a transcript entry: a history entry is
 * `{type:'message', message:{…}}`; a bare message is itself. */
function entryMessage(entry: unknown): Record<string, unknown> | null {
  const obj = asObject(entry);
  if (obj === null) return null;
  if (obj.message !== undefined) return asObject(obj.message);
  return obj;
}

/** Indexes every assistant tool-call argument by call id across the entries. */
function collectToolArgs(entries: readonly unknown[]): Map<string, unknown> {
  const argsById = new Map<string, unknown>();
  for (const entry of entries) {
    const message = entryMessage(entry);
    if (message === null || message.role !== 'assistant' || !Array.isArray(message.content)) {
      continue;
    }
    for (const part of message.content) {
      const call = asObject(part);
      if (call === null || call.type !== 'toolCall') continue;
      const id = asString(call.id);
      if (id !== null) argsById.set(id, call.arguments);
    }
  }
  return argsById;
}

/**
 * Replays entries with synthesized `tool` frames inserted after each assistant
 * tool call and each tool result, so a snapshot carries the same normalized
 * views as the live relay. Every inserted frame is bounded; non-message entries
 * are copied through untouched.
 */
export function annotateToolViews(entries: readonly unknown[]): unknown[] {
  const argsById = collectToolArgs(entries);
  const annotated: unknown[] = [];
  for (const entry of entries) {
    annotated.push(entry);
    const message = entryMessage(entry);
    if (message === null) continue;
    if (message.role === 'assistant') {
      for (const payload of toolCallPayloads(message, argsById)) {
        annotated.push(boundToolPayload(payload));
      }
    } else if (message.role === 'toolResult') {
      const payload = toolResultPayload(message, argsById);
      if (payload !== null) annotated.push(boundToolPayload(payload));
    }
  }
  return annotated;
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
  'listModels',
  'listTree',
  'sessionNew',
  'sessionTree',
  'sessionFork',
]);

/**
 * The bridge's own registered command. Its sole purpose is to hand the handler
 * a real `ExtensionCommandContext`, the only surface exposing
 * `newSession`/`fork`/`navigateTree`.
 */
export const SESSION_COMMAND_NAME = 'pi-droid-session';

/** The most `/tree` nodes a `listTree` result may carry. */
export const TREE_MAX_NODES = 200;

/**
 * The refusal for a command name the bridge will not dispatch — either because
 * the allowlist has no such name, or because the allowlist has it and the
 * dispatcher has no case for it.
 *
 * Exported and shared so the guard test pins the *path*, not a copy of the
 * string: with two literals, editing one would let a missing case answer with a
 * different message and the guard would pass over a real hole.
 */
export const COMMAND_NOT_ALLOWED = 'command not allowed';

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
 * Flattens pi's session tree into the picker's bounded node list.
 *
 * Only a `message` entry whose role is `user`/`assistant` is emitted; every
 * other entry (the other `SessionEntry` variants, tool results, system/custom
 * messages) is traversed but not emitted, so message nodes below it are still
 * reached.
 *
 * `getTree()` is typed `unknown` here because the bridge's pi slice is
 * structural, so every access is defensive: a malformed node is skipped, never
 * thrown. It is called inside dispatch, where a throw would surface as a
 * generic refusal.
 *
 * Nodes are flattened in DFS order (parents before children, children in array
 * order) and the newest `cap` are kept. An emitted node whose parent was
 * dropped off the front is relinked to the top, so the app's indentation can
 * never point at a missing id.
 */
export function projectTree(
  roots: unknown,
  cap = TREE_MAX_NODES,
): { nodes: TreeNodeSummary[]; truncated: boolean } {
  const emitted: Array<{ node: TreeNodeSummary; parentId: string | null }> = [];

  const visit = (raw: unknown, nearestEmittedId: string | null): void => {
    const treeNode = asObject(raw);
    if (treeNode === null) return;
    const entry = asObject(treeNode.entry);
    if (entry === null) return;
    const id = asString(entry.id);
    const message = asObject(entry.message);
    const role = message === null ? undefined : asString(message.role);
    let nextNearest = nearestEmittedId;
    if (entry.type === 'message' && id !== null && (role === 'user' || role === 'assistant')) {
      const node: TreeNodeSummary = {
        id,
        parentId: nearestEmittedId,
        role,
        text: projectedMessageText(role, message as Record<string, unknown>),
      };
      const label = asString(treeNode.label);
      if (label !== null) node.label = label;
      emitted.push({ node, parentId: nearestEmittedId });
      nextNearest = id;
    }
    const children = treeNode.children;
    if (!Array.isArray(children)) return;
    for (const child of children) visit(child, nextNearest);
  };

  if (Array.isArray(roots)) {
    for (const root of roots) visit(root, null);
  }

  const truncated = emitted.length > cap;
  const kept = truncated ? emitted.slice(emitted.length - cap) : emitted;
  const keptIds = new Set(kept.map((item) => item.node.id));
  const nodes = kept.map((item) =>
    item.parentId !== null && keptIds.has(item.parentId)
      ? item.node
      : { ...item.node, parentId: null },
  );
  return { nodes, truncated };
}

/**
 * The text of one emitted node. A user message's content may be a string or
 * parts; an image part is marked rather than dropped. Only assistant text parts
 * count — thinking and tool calls contribute nothing, so a pure tool-call turn
 * legitimately has empty text.
 */
function projectedMessageText(
  role: 'user' | 'assistant',
  message: Record<string, unknown>,
): string {
  const content = message.content;
  if (role === 'user' && typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  let text = '';
  for (const part of content) {
    const obj = asObject(part);
    if (obj === null) continue;
    if (role === 'user') {
      if (obj.type === 'text' && typeof obj.text === 'string') text += obj.text;
      else text += '[image]';
    } else if (obj.type === 'text' && typeof obj.text === 'string') {
      text += obj.text;
    }
  }
  return text;
}

/**
 * Projects a pi `Model` onto the three fields the app needs. Deliberately not a
 * passthrough: a `Model` carries `headers` (credentials), `baseUrl`, `compat`
 * and cost data, none of which may leave the bridge. Returns null unless
 * `provider`, `id` and `name` are all strings, so a malformed registry entry is
 * skipped rather than sent half-formed.
 */
function projectModel(value: unknown): ModelSummary | null {
  const model = asObject(value);
  if (model === null) return null;
  const provider = asString(model.provider);
  const id = asString(model.id);
  const name = asString(model.name);
  if (provider === null || id === null || name === null) return null;
  return { provider, id, name };
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
  models?: ModelSummary[];
  queued?: boolean;
  tree?: TreeNodeSummary[];
  treeTruncated?: boolean;
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
  /** Tool-call arguments by call id, so a `toolResult` (which carries none) can
   * resolve its path/command. Seeded from the session entries at start and kept
   * current as assistant messages land. */
  private readonly toolArgs = new Map<string, unknown>();
  /** The current turn's final assistant snippet, reset at each turn start. */
  private lastSettled: { text: string; truncated: boolean } = { text: '', truncated: false };
  private attempt = 0;
  private reconnectTimer: unknown = null;
  private closed = false;
  /** The hub session id last reported by `session_start`. */
  private registeredSessionId: string | null = null;
  /** The id the next register must name as replaced, consumed only on a send. */
  private replacesSessionId: string | null = null;
  /** Guards the one-time internal command registration. */
  private sessionCommandsRegistered = false;

  constructor(pi: BridgePi, deps: ResolvedDeps) {
    this.pi = pi;
    this.deps = deps;
    this.debug = (stream, text) => {
      if (deps.env.PI_DROID_DEBUG === '1') deps.write(stream, text);
    };
  }

  install(): void {
    this.registerSessionCommand();
    // The socket is opened here, in the handler, never in the factory. Every
    // pi callback is guarded so an exception cannot escape into pi (which would
    // print to stderr and take the session down).
    this.pi.on('session_start', (event, ctx) =>
      this.guard(() => this.onSessionStart(ctx, event)),
    );
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
    // A PC-side `/model` change: the app's model label must follow without
    // waiting for the next turn, exactly as the thinking level does. `setModel`
    // also re-baselines directly, because `_emitModelSelect` early-returns for
    // an equal-model switch and the direct emit is then the only frame.
    this.pi.on('model_select', () => this.guard(() => this.sendUsageEvent()));
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

  private registerSessionCommand(): void {
    if (this.sessionCommandsRegistered) return;
    this.sessionCommandsRegistered = true;
    this.pi.registerCommand?.(SESSION_COMMAND_NAME, {
      description: 'Drive pi session actions from the pi-droid app',
      handler: (args, ctx) => this.onSessionCommand(args, ctx),
    });
  }

  /**
   * Runs inside a real pi command context. pi invalidates that context after
   * `newSession`/`fork`, so the handler performs exactly one action and returns;
   * any notice is emitted on the bridge's own socket, never on the context.
   */
  private async onSessionCommand(args: string, cmdCtx: BridgeCommandCtx): Promise<void> {
    const [action, target] = args.trim().split(/\s+/, 2);
    try {
      if (action === 'new') {
        const result = await cmdCtx.newSession();
        if (result.cancelled) this.sendStatusError('the new session was cancelled');
        return;
      }
      if (action === 'tree') {
        if (target === undefined) {
          this.sendStatusError('the tree target is missing');
          return;
        }
        const result = await cmdCtx.navigateTree(target);
        if (result.cancelled) this.sendStatusError('the tree navigation was cancelled');
        return;
      }
      if (action === 'fork') {
        if (target === undefined) {
          this.sendStatusError('the fork target is missing');
          return;
        }
        const result = await cmdCtx.fork(target);
        if (result.cancelled) this.sendStatusError('the fork was cancelled');
        return;
      }
      // An unknown action (empty or mistyped) must not fall through silently:
      // `dispatch` already acked `ok:true`, so the only signal the app gets is
      // this notice.
      this.sendStatusError(`unknown session action: ${action || '(empty)'}`);
      return;
    } catch (error) {
      // pi invalidates the context after `newSession`/`fork`, and this branch
      // never touches `cmdCtx` again — the notice goes out on the bridge's own
      // socket. A throw is surfaced, never left as an unhandled rejection.
      this.sendStatusError(error instanceof Error ? error.message : String(error));
    }
  }

  /** Emits a notice the app renders in the transcript. */
  private sendStatusError(message: string): void {
    this.sendEvent({ kind: 'status', event: 'error', message });
  }

  private onSessionStart(ctx: BridgeCtx, event: unknown): void {
    const reason =
      typeof event === 'object' && event !== null
        ? (event as { reason?: unknown }).reason
        : undefined;
    const sessionId = ctx.sessionManager.getSessionId();
    // A replacement (`/new`, `/fork`, `/resume`) re-fires `session_start` under
    // a new id; the successor's register names the id it replaced so the app can
    // follow it instead of treating the new id as an unrelated session. `/resume`
    // can reload the same id, so "differs" is part of the condition.
    if (
      (reason === 'new' || reason === 'fork' || reason === 'resume') &&
      this.registeredSessionId !== null &&
      this.registeredSessionId !== sessionId
    ) {
      this.replacesSessionId = this.registeredSessionId;
    }
    this.registeredSessionId = sessionId;
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
    // A resumed session's earlier tool calls are already in the entries, so a
    // result that arrives after this point still resolves its args.
    this.toolArgs.clear();
    try {
      for (const [id, args] of collectToolArgs(ctx.sessionManager.getEntries())) {
        this.toolArgs.set(id, args);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.debug('stderr', `pi-droid bridge: tool-arg seeding failed: ${message}\n`);
    }
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

  private send(message: AgentToHubMessage): boolean {
    if (this.socket === null || this.socket.readyState !== SOCKET_OPEN) return false;
    this.socket.send(encodeAgentMessage(message));
    return true;
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
    const replaces = this.replacesSessionId;
    if (replaces !== null) message.replaces = replaces;
    this.lastLabel = label;
    if (this.send(message) && replaces !== null) {
      // Consumed only by a register that actually reached the wire: a dropped
      // register never told the hub, so the linkage must survive for the next
      // real one.
      this.replacesSessionId = null;
    }
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
    // A tool call/result follows its own message frame, so the app can pair the
    // normalized view with the row the message produced.
    const original = (event as { message?: unknown }).message;
    const originalRole =
      typeof original === 'object' && original !== null
        ? (original as { role?: unknown }).role
        : undefined;
    if (originalRole === 'assistant') {
      for (const payload of toolCallPayloads(original, this.toolArgs)) {
        this.sendEvent(boundToolPayload(payload));
      }
      for (const [id, args] of collectToolArgs([original])) this.toolArgs.set(id, args);
    } else if (originalRole === 'toolResult') {
      const payload = toolResultPayload(original, this.toolArgs);
      if (payload !== null) this.sendEvent(boundToolPayload(payload));
    }
    // The snippet comes from the ORIGINAL message, never the bounded payload:
    // an oversized reply is replaced by a `{truncated:true,bytes}` marker, and
    // caching that marker would make every huge reply notify `'No reply'`.
    if (originalRole === 'assistant') {
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
        this.sendCommandResult(command.id, false, COMMAND_NOT_ALLOWED);
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
        outcome.models,
        outcome.tree,
        outcome.treeTruncated,
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
        // pi's AgentSession.setModel has no streaming guard: mid-turn it mutates
        // agent.state.model under the in-flight call and cascades a thinking-level
        // clamp. The phone cannot see streaming state, so refuse visibly rather
        // than put the session on a mixed-model turn. Best-effort: isIdle() is
        // read here with no await before setModel.
        if (!ctx.isIdle()) return { ok: false, error: 'cannot switch the model while pi is working' };
        const provider = asString(fields.provider);
        const id = asString(fields.id);
        if (provider === null || id === null) return { ok: false, error: 'missing model' };
        const registry = ctx.modelRegistry;
        if (registry === undefined || typeof registry.find !== 'function') {
          return { ok: false, error: 'models unavailable' };
        }
        const model = registry.find(provider, id);
        if (model === undefined || model === null) return { ok: false, error: 'model not found' };
        const accepted = await this.pi.setModel(model);
        // Kept even though `model_select` also re-reports: `_emitModelSelect`
        // early-returns for an equal model, so a same-model switch would emit
        // nothing. A duplicate on a real switch is harmless and idempotent.
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
          // Hide the bridge's own command: the bare name and pi's `:N` duplicate
          // form. A `pi-droid-session-foo` tail is a different, real command.
          if (name === SESSION_COMMAND_NAME || name.startsWith(`${SESSION_COMMAND_NAME}:`)) {
            continue;
          }
          const command: SlashCommand = { name };
          const description = asString((entry as { description?: unknown })?.description);
          if (description !== null) command.description = description;
          commands.push(command);
        }
        return { ok: true, commands };
      }
      case 'listModels': {
        const registry = ctx.modelRegistry;
        if (registry === undefined || typeof registry.getAvailable !== 'function') {
          return { ok: false, error: 'models unavailable' };
        }
        const raw = registry.getAvailable();
        if (!Array.isArray(raw)) return { ok: false, error: 'models unavailable' };
        const models: ModelSummary[] = [];
        for (const entry of raw) {
          const model = projectModel(entry);
          if (model !== null) models.push(model);
        }
        return { ok: true, models };
      }
      case 'listTree': {
        const manager = ctx.sessionManager;
        if (typeof manager.getTree !== 'function') {
          return { ok: false, error: 'tree unavailable' };
        }
        const projection = projectTree(manager.getTree(), TREE_MAX_NODES);
        return { ok: true, tree: projection.nodes, treeTruncated: projection.truncated };
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
      case 'sessionNew':
        return this.triggerSessionAction('new');
      case 'sessionTree': {
        // `navigateTree` is in place but throws on a streaming/compacting
        // session, so refuse synchronously rather than let pi throw later.
        if (!ctx.isIdle()) {
          return { ok: false, error: 'cannot navigate the tree while pi is working' };
        }
        const entryId = asString(fields.entryId);
        if (entryId === null) return { ok: false, error: 'missing entry' };
        return this.triggerSessionAction('tree', entryId);
      }
      case 'sessionFork': {
        const entryId = asString(fields.entryId);
        if (entryId === null) return { ok: false, error: 'missing entry' };
        // Validate the target here, at dispatch: an entry can be invalidated by
        // a turn landing between the app listing the tree and tapping a node.
        const entry = asObject(ctx.sessionManager.getEntry(entryId));
        const message = entry === null ? null : asObject(entry.message);
        // The target must be a *message* entry with role `user` (pi's default
        // `position:'before'` fork requirement). A non-message entry that merely
        // carries a `message` object must be refused here, at dispatch — not
        // later as a status error after `ok:true` was already acked.
        if (entry?.type !== 'message' || message === null || message.role !== 'user') {
          return { ok: false, error: 'unknown entry' };
        }
        return this.triggerSessionAction('fork', entryId);
      }
      default:
        return { ok: false, error: COMMAND_NOT_ALLOWED };
    }
  }

  /**
   * Triggers the bridge's own registered command — the only route to a real
   * command context. Fire-and-forget, exactly like `sendUserMessage`; the
   * replacement itself (or a status notice) is what confirms the outcome.
   */
  private triggerSessionAction(action: string, target?: string): CommandOutcome {
    const text =
      target === undefined
        ? `/${SESSION_COMMAND_NAME} ${action}`
        : `/${SESSION_COMMAND_NAME} ${action} ${target}`;
    this.pi.sendUserMessage(text, { expandPromptTemplates: true });
    return { ok: true };
  }

  private sendHistory(): void {
    const ctx = this.ctx;
    if (ctx === null) return;
    // The snapshot carries the same normalized tool views as the live relay, so
    // a reconnecting or history-loading viewer does not need to re-derive them.
    const projection = projectHistory(
      annotateToolViews(ctx.sessionManager.getEntries()),
      HISTORY_MAX_BYTES,
    );
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
    const payload: ContextUsagePayload = {
      kind: 'usage',
      tokens: usage.tokens,
      contextWindow: usage.contextWindow,
    };
    const level = ctx.thinkingLevel;
    if (typeof level === 'string') payload.thinkingLevel = level;
    const model = projectModel(ctx.model);
    if (model !== null) payload.model = model;
    this.sendEvent(payload);
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
    models?: ModelSummary[],
    tree?: TreeNodeSummary[],
    treeTruncated?: boolean,
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
    if (models !== undefined) message.models = models;
    if (tree !== undefined) message.tree = tree;
    if (treeTruncated !== undefined) message.treeTruncated = treeTruncated;
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
