/** The command allowlist, the internal session command, and mode gating. */

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
export const SESSION_COMMAND_NAME = 'pi-handset-session';

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
