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
import { HISTORY_MAX_BYTES, PROTOCOL_VERSION, asString } from '../src/protocol/protocol.ts';
import type {
  AgentState,
  AgentToHubMessage,
  CommandMessage,
  ContextUsagePayload,
  EventPayload,
  HistoryMessage,
  ModelSummary,
  SlashCommand,
  TreeNodeSummary,
} from '../src/protocol/protocol.ts';
import type { BridgeCommandCtx, BridgeCtx, BridgePi, SocketFactory, BridgeDeps } from '../src/bridge/pi-types.ts';
import { annotateToolViews, projectHistory, entryAnchor, mintCursor, parseHistoryCursor, projectModel, readContextUsage } from '../src/bridge/history.ts';
import { sanitizeLabel, labelFromMessage, labelFromEntries } from '../src/bridge/labels.ts';
import { parseCommand } from '../src/bridge/wire.ts';
import { commandResultMessage, eventMessage, helloMessage, registerMessage } from '../src/bridge/outbound.ts';
import { isActiveMode, COMMAND_ALLOWLIST, SESSION_COMMAND_NAME, COMMAND_NOT_ALLOWED } from '../src/bridge/commands.ts';
import { dispatchCommand } from '../src/bridge/command-dispatch.ts';
import { createRelay, type Relay } from '../src/bridge/relay.ts';
import { createSocketLink, type SocketLink } from '../src/bridge/socket-link.ts';


/**
 * The hub session id the most recently installed bridge registered.
 *
 * Deliberately module scope, not instance scope: pi re-runs the extension
 * factory for every session replacement (the new runtime reloads its resource
 * loader), so the successor's bridge is a *different* instance and instance
 * state cannot name the session it replaced. The module is imported once per
 * pi process, so this value survives the reload and lets the successor carry
 * `replaces`. A `startup` event is a fresh process and overwrites it like any
 * other; a `new`/`fork`/`resume` that differs from it is a real replacement.
 */
let lastRegisteredSessionId: string | null = null;

/**
 * Test-only: clears the module-level predecessor so a unit test cannot inherit
 * a linkage recorded by an earlier test. Production never calls this — a fresh
 * process starts with `null` and every real session transition overwrites it
 * via `onSessionStart`.
 */
export function resetSessionLinkageForTests(): void {
  lastRegisteredSessionId = null;
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

interface ResolvedDeps {
  env: NodeJS.ProcessEnv;
  socketFactory: SocketFactory;
  resolveEndpoint: () => BridgeEndpoint | null;
  write: (stream: 'stderr', text: string) => void;
  rng: () => number;
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (handle: unknown) => void;
}

function resolveDeps(deps: BridgeDeps): ResolvedDeps {
  return {
    env: deps.env ?? process.env,
    // Native WebSocket only — no `ws` in the extension.
    socketFactory: deps.socketFactory ?? ((url) => new WebSocket(url)),
    resolveEndpoint: deps.resolveEndpoint ?? (() => readEndpoint()),
    write: deps.write ?? ((_stream, text) => process.stderr.write(text)),
    rng: deps.rng ?? Math.random,
    setTimeout: deps.setTimeout ?? ((fn, ms) => setTimeout(fn, ms)),
    clearTimeout: deps.clearTimeout ?? ((handle) => clearTimeout(handle as NodeJS.Timeout)),
  };
}

class Bridge {
  private readonly pi: BridgePi;
  private readonly debug: (stream: 'stderr', text: string) => void;
  private readonly relay: Relay;
  private readonly link: SocketLink;
  private ctx: BridgeCtx | null = null;
  private lastLabel: string | null = null;
  private state: AgentState = 'idle';
  /** The id the next register must name as replaced, consumed only on a send. */
  private replacesSessionId: string | null = null;
  /** Guards the one-time internal command registration. */
  private sessionCommandsRegistered = false;

  constructor(pi: BridgePi, deps: ResolvedDeps) {
    this.pi = pi;
    this.debug = (stream, text) => {
      if (deps.env.PI_DROID_DEBUG === '1') deps.write(stream, text);
    };
    this.relay = createRelay({ sendEvent: (payload) => this.sendEvent(payload), relabelFromMessage: (message) => this.relabelFromMessage(message) });
    this.link = createSocketLink({ socketFactory: deps.socketFactory, resolveEndpoint: deps.resolveEndpoint, rng: deps.rng, setTimeout: deps.setTimeout, clearTimeout: deps.clearTimeout, debug: (text) => this.debug('stderr', text), guard: (run) => this.guard(run) }, { onOpen: (token) => this.onSocketOpen(token), onFrame: (event) => this.onMessage(event) });
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
    this.pi.on('message_update', (event) => this.guard(() => this.relay.onMessageUpdate(event)));
    // Real pi's assistant-completion signal. `message_update` never carries a
    // `done`, so this is the only live source of the `message` payload.
    this.pi.on('message_end', (event) => this.guard(() => this.relay.onMessageEnd(event)));
    // `/session-name` in the TUI emits `session_info_changed`; subscribing keeps
    // the phone's label current without waiting for the next prompt.
    this.pi.on('session_info_changed', () =>
      this.guard(() => this.refreshLabel(this.currentLabel())),
    );
    this.pi.on('agent_start', () =>
      this.guard(() => {
        this.relay.resetTurn();
        this.setAgentState('running');
      }),
    );
    // Terminal state is `agent_settled`, deliberately not `agent_end`.
    this.pi.on('agent_settled', () =>
      this.guard(() => {
        this.relay.clearHeldArgs();
        this.setAgentState('settled');
        this.sendUsageEvent();
        this.relay.sendSettled();
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
    // A leaf move — the app's own tap or a PC-side `/tree` — is the one signal
    // that the branch changed. pi emits it after `branch()`/`resetLeaf()`, so a
    // re-requesting viewer re-baselines on the new branch. Guarded like every
    // other subscription so a mapping failure cannot escape into pi.
    this.pi.on('session_tree', (event) => this.guard(() => this.relay.onSessionTree(event)));
    // `ctx.compact()` is fire-and-forget and passes no `onError`, so a failed
    // compaction is otherwise invisible. Surface every reason (manual, overflow,
    // threshold) — an auto-compaction failure is more consequential, not less.
    // pi emits this from the `catch` of both compaction paths, so the indicator
    // raised above is always cleared — including when the compaction was aborted
    // rather than failed.
    this.pi.on('session_compact_failed', (event) =>
      this.guard(() => {
        this.sendCompactingEvent(false);
        this.relay.onCompactFailed(event);
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
      lastRegisteredSessionId !== null &&
      lastRegisteredSessionId !== sessionId
    ) {
      this.replacesSessionId = lastRegisteredSessionId;
    }
    lastRegisteredSessionId = sessionId;
    // Session replacement invalidates the previous context: drop the old
    // socket and every session-scoped value before binding the new context.
    this.link.startSession();
    this.ctx = ctx;
    this.relay.resetSession();
    this.state = 'idle';
    try {
      this.relay.seedToolArgs(ctx.sessionManager.getEntries());
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.debug('stderr', `pi-droid bridge: tool-arg seeding failed: ${message}\n`);
    }
    if (!isActiveMode(ctx.mode)) {
      this.debug('stderr', `pi-droid bridge: inert in ${ctx.mode} mode\n`);
      return;
    }
    this.link.open();
  }

  private onSessionShutdown(): void {
    this.link.stop();
    this.ctx = null;
  }

  private onSocketOpen(token: string): void {
    this.send(helloMessage(token));
    this.sendRegister(this.currentLabel());
    this.sendAgentState();
  }

  private send(message: AgentToHubMessage): boolean {
    return this.link.send(message);
  }

  private sendEvent(payload: EventPayload): void {
    this.send(eventMessage(payload));
  }

  private sendRegister(label: string | null): void {
    const ctx = this.ctx;
    if (ctx === null) return;
    const manager = ctx.sessionManager;
    const replaces = this.replacesSessionId;
    const message = registerMessage({
      sessionId: manager.getSessionId(),
      sessionFile: manager.getSessionFile(),
      cwd: ctx.cwd,
      mode: ctx.mode,
      pid: process.pid,
      model: ctx.model?.id,
      thinkingLevel: ctx.thinkingLevel,
      name: label,
      replaces,
    });
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

  private relabelFromMessage(message: unknown): void {
    this.refreshLabel(this.resolveLabel(() => labelFromMessage(message)));
  }

  private sendAgentState(): void {
    this.sendEvent({ kind: 'agent', state: this.state });
  }

  private setAgentState(state: AgentState): void {
    this.state = state;
    this.sendEvent({ kind: 'agent', state });
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
    else if (message.type === 'history-request') this.sendHistory(asString(message.cursor) ?? undefined);
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
      const outcome = await dispatchCommand(this.pi, ctx, command.name, command.args, { relabel: () => this.refreshLabel(this.currentLabel()), reportUsage: () => this.sendUsageEvent() });
      this.sendCommandResult(
        command.id,
        outcome.ok,
        outcome.error,
        outcome.commands,
        outcome.queued,
        outcome.models,
        outcome.tree,
        outcome.treeTruncated,
        outcome.leafId,
      );
    } catch (error) {
      this.sendCommandResult(
        command.id,
        false,
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  private sendHistory(cursor?: string): void {
    const ctx = this.ctx;
    if (ctx === null) return;
    // The snapshot carries the same normalized tool views as the live relay, so
    // a reconnecting or history-loading viewer does not need to re-derive them.
    // The projection is the ACTIVE BRANCH (`buildContextEntries`), not the whole
    // file: navigating the tree only moves a leaf, so a whole-file replay would
    // never change. Fall back to `getEntries()` on an older pi that lacks it.
    const manager = ctx.sessionManager;
    const entries =
      typeof manager.buildContextEntries === 'function'
        ? manager.buildContextEntries()
        : manager.getEntries();
    const annotated = annotateToolViews(entries);
    const requested = cursor ?? null;
    // Honour the cursor only when the anchor digests the ORIGINAL entry at the
    // offset (never a collapsed marker) and the offset is in range; anything
    // else degrades to a fresh newest page, never an error.
    const parsed = requested === null ? null : parseHistoryCursor(requested);
    const honoured =
      parsed !== null &&
      parsed.offset < annotated.length &&
      entryAnchor(parsed.offset, annotated[parsed.offset]) === parsed.anchor;
    const page = honoured
      ? projectHistory(annotated, HISTORY_MAX_BYTES, parsed.offset)
      : projectHistory(annotated, HISTORY_MAX_BYTES);
    const message: HistoryMessage = {
      protocolVersion: PROTOCOL_VERSION,
      type: 'history',
      sessionId: ctx.sessionManager.getSessionId(),
      entries: page.entries,
      truncated: page.truncated,
      // The routing token is echoed whenever the request had one, honoured or
      // not; `older` is present only when the page is genuinely older, and the
      // next cursor only while older entries remain.
      ...(requested !== null ? { cursor: requested } : {}),
      ...(honoured ? { older: true } : {}),
      ...(page.start > 0 ? { olderCursor: mintCursor(annotated, page.start) } : {}),
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

  private sendCommandResult(
    id: string,
    ok: boolean,
    error?: string,
    commands?: SlashCommand[],
    queued?: boolean,
    models?: ModelSummary[],
    tree?: TreeNodeSummary[],
    treeTruncated?: boolean,
    leafId?: string | null,
  ): void {
    this.send(commandResultMessage(id, ok, { error, commands, queued, models, tree, treeTruncated, leafId }));
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
