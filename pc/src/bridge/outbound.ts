/** Building the agent's outbound frames from plain values. */

import { PROTOCOL_VERSION } from '../protocol/protocol.ts';
import type { CommandResultMessage, EventMessage, EventPayload, HelloMessage, ModelSummary, RegisterMessage, SlashCommand, TreeNodeSummary } from '../protocol/protocol.ts';

/** The handshake frame: a token credential, never a ticket. */
export function helloMessage(token: string): HelloMessage {
  return { protocolVersion: PROTOCOL_VERSION, type: 'hello', token };
}

/** Wraps a normalized payload in the single agent→hub event frame. */
export function eventMessage(payload: EventPayload): EventMessage {
  return { protocolVersion: PROTOCOL_VERSION, type: 'event', payload };
}

/**
 * The values a register frame is built from. Every field is optional except the
 * session id, mirroring what the bridge knows at register time.
 */
export interface RegisterInput {
  sessionId: string;
  sessionFile?: string;
  cwd?: string;
  mode?: string;
  pid?: number;
  model?: string;
  thinkingLevel?: string;
  name?: string | null;
  replaces?: string | null;
}

/**
 * The session registration frame. `sessionId`/`sessionFile`/`cwd`/`mode`/
 * `pid` are always set — the original literal always carried the
 * `sessionFile` key, even as `undefined`, and a `deepStrictEqual` sees the
 * difference. The rest are set only when present.
 */
export function registerMessage(input: RegisterInput): RegisterMessage {
  const message: RegisterMessage = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: input.sessionId,
    sessionFile: input.sessionFile,
    cwd: input.cwd,
    mode: input.mode,
    pid: input.pid,
  };
  if (input.model !== undefined) message.model = input.model;
  if (input.thinkingLevel !== undefined) message.thinkingLevel = input.thinkingLevel;
  if (input.name != null) message.name = input.name;
  if (input.replaces != null) message.replaces = input.replaces;
  return message;
}

/** The optional result fields a command-result frame may carry. */
export interface CommandResultFields {
  error?: string;
  commands?: SlashCommand[];
  queued?: boolean;
  models?: ModelSummary[];
  tree?: TreeNodeSummary[];
  treeTruncated?: boolean;
  leafId?: string | null;
}

/** A command-result frame; each field is present only when supplied. */
export function commandResultMessage(id: string, ok: boolean, fields: CommandResultFields = {}): CommandResultMessage {
  const message: CommandResultMessage = {
    protocolVersion: PROTOCOL_VERSION,
    type: 'command-result',
    id,
    ok,
  };
  if (fields.error !== undefined) message.error = fields.error;
  if (fields.commands !== undefined) message.commands = fields.commands;
  if (fields.queued !== undefined) message.queued = fields.queued;
  if (fields.models !== undefined) message.models = fields.models;
  if (fields.tree !== undefined) message.tree = fields.tree;
  if (fields.treeTruncated !== undefined) message.treeTruncated = fields.treeTruncated;
  if (fields.leafId !== undefined) message.leafId = fields.leafId;
  return message;
}
