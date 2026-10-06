/**
 * The structural slice of pi's extension API the bridge touches.
 *
 * A type-only import of `@earendil-works/pi-coding-agent` would make `pc/`
 * depend on the host package just to typecheck, so these declarations mirror
 * only what the bridge reads. `AssistantMessageEvent` is transcribed from
 * `pi-ai/dist/types.d.ts`.
 */

import type { SlashCommand } from '../protocol/protocol.ts';
// BridgeDeps names the entry's BridgeEndpoint, so the only cycle is type-only.
import type { BridgeEndpoint } from '../../extensions/pi-droid-bridge.ts';

// ---------------------------------------------------------------------------
// The slice of the pi extension API the bridge uses
// ---------------------------------------------------------------------------

/**
 * A registered pi event handler. Pi passes `(event, ctx)`.
 *
 * This is the boundary where pi's untyped event union enters the bridge, on
 * purpose: each handler narrows the event itself, and `unknown` here would
 * force that narrowing onto every call site.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
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
  /**
   * The active branch's context entries — branch plus compaction projection.
   * Optional: absent on an older pi, where whole-file `getEntries()` is the
   * fallback. `sendHistory` prefers this so the transcript follows the leaf.
   */
  buildContextEntries?(): unknown[];
  /** The tree's current leaf, or `null` for the root. Optional, like `getTree`. */
  getLeafId?(): string | null;
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

/** A text part of a pi user message. */
export interface TextPart {
  type: 'text';
  text: string;
}

/** A flat pi image content part, matching `pi-ai`'s `ImageContent`. */
export interface ImagePart {
  type: 'image';
  data: string;
  mimeType: string;
}

/** Pi user-message content: plain text, or a text part plus images. */
export type UserMessageContent = string | (TextPart | ImagePart)[];

/** The extension API, narrowed to what the bridge calls. */
export interface BridgePi {
  on(event: string, handler: BridgeHandler): () => void;
  sendUserMessage(
    content: UserMessageContent,
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

/** The pi `message_end` extension event: the authoritative final message. */
export interface MessageEndEvent {
  type: 'message_end';
  message: unknown;
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
