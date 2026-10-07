/** Running a hub command against the live session. */

import { asObject, asString } from '../protocol/protocol.ts';
import type { SlashCommand, ModelSummary, TreeNodeSummary } from '../protocol/protocol.ts';
import { parseImages } from './normalize.ts';
import { projectModel, projectTree, TREE_MAX_NODES } from './history.ts';
import { SESSION_COMMAND_NAME, COMMAND_NOT_ALLOWED } from './commands.ts';
import type { BridgeCtx, BridgePi, UserMessageContent } from './pi-types.ts';

export interface CommandOutcome {
  ok: boolean;
  error?: string;
  commands?: SlashCommand[];
  models?: ModelSummary[];
  queued?: boolean;
  tree?: TreeNodeSummary[];
  treeTruncated?: boolean;
  /** The current leaf, on a `listTree` result; `null` is the root. */
  leafId?: string | null;
}

export interface DispatchHooks { relabel(): void; reportUsage(): void }

export async function dispatchCommand(
  pi: BridgePi,
  ctx: BridgeCtx,
  name: string,
  args: unknown,
  hooks: DispatchHooks,
): Promise<CommandOutcome> {
  const fields = asObject(args) ?? {};
  switch (name) {
    case 'prompt':
    case 'steer':
    case 'followup': {
      const text = asString(fields.text);
      if (text === null) return { ok: false, error: 'missing text' };
      const imagesResult = parseImages(fields.images);
      if (!imagesResult.ok) return { ok: false, error: 'malformed images' };
      const content: UserMessageContent =
        imagesResult.images === undefined
          ? text
          : [{ type: 'text', text }, ...imagesResult.images];
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
      pi.sendUserMessage(content, {
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
      const accepted = await pi.setModel(model);
      // Kept even though `model_select` also re-reports: `_emitModelSelect`
      // early-returns for an equal model, so a same-model switch would emit
      // nothing. A duplicate on a real switch is harmless and idempotent.
      if (accepted) hooks.reportUsage();
      return accepted ? { ok: true } : { ok: false, error: 'model not accepted' };
    }
    case 'setThinkingLevel': {
      const level = asString(fields.level);
      if (level === null) return { ok: false, error: 'missing level' };
      pi.setThinkingLevel(level);
      return { ok: true };
    }
    case 'compact':
      ctx.compact();
      return { ok: true };
    case 'listCommands': {
      const raw = pi.getCommands?.();
      if (raw === undefined || !Array.isArray(raw)) {
        return { ok: false, error: 'commands unavailable' };
      }
      const commands: SlashCommand[] = [];
      for (const entry of raw) {
        const name = asString((entry as { name?: unknown })?.name);
        if (name === null) continue;
        // Hide the bridge's own command: the bare name and pi's `:N` duplicate
        // form. A `pi-handset-session-foo` tail is a different, real command.
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
      const leafId = typeof manager.getLeafId === 'function' ? manager.getLeafId() : null;
      return {
        ok: true,
        tree: projection.nodes,
        treeTruncated: projection.truncated,
        leafId,
      };
    }
    case 'setSessionName': {
      const sessionName = asString(fields.name);
      if (sessionName === null) return { ok: false, error: 'missing name' };
      pi.setSessionName(sessionName);
      // Read the (possibly normalized) name back: a rename is a label change
      // even when it was made elsewhere.
      hooks.relabel();
      return { ok: true };
    }
    case 'sessionNew':
      return triggerSessionAction(pi, 'new');
    case 'sessionTree': {
      // `navigateTree` is in place but throws on a streaming/compacting
      // session, so refuse synchronously rather than let pi throw later.
      if (!ctx.isIdle()) {
        return { ok: false, error: 'cannot navigate the tree while pi is working' };
      }
      const entryId = asString(fields.entryId);
      if (entryId === null) return { ok: false, error: 'missing entry' };
      // Validate the target here, at dispatch, exactly as `sessionFork` does:
      // `triggerSessionAction` only acks that pi accepted the request, and a
      // stale id would then surface as a `status/error` long after the app
      // moved on. pi resolves non-message entries too (the leaf becomes the
      // entry), so only resolution is required, not a role.
      if (asObject(ctx.sessionManager.getEntry(entryId)) === null) {
        return { ok: false, error: 'unknown entry' };
      }
      return triggerSessionAction(pi, 'tree', entryId);
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
      return triggerSessionAction(pi, 'fork', entryId);
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
function triggerSessionAction(pi: BridgePi, action: string, target?: string): CommandOutcome {
  const text =
    target === undefined
      ? `/${SESSION_COMMAND_NAME} ${action}`
      : `/${SESSION_COMMAND_NAME} ${action} ${target}`;
  pi.sendUserMessage(text, { expandPromptTemplates: true });
  return { ok: true };
}
