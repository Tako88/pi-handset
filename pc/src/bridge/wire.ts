/** Encoding an agent frame and parsing a hub command frame. */

import { PROTOCOL_VERSION, asString, encode } from '../protocol/protocol.ts';
import type { AgentToHubMessage, CommandMessage } from '../protocol/protocol.ts';

export function encodeAgentMessage(message: AgentToHubMessage): string {
  // `encode` is the protocol module's single-object encoder for the message
  // types it fully owns (hello/event); the rest are typed by protocol.ts too.
  if (message.type === 'hello' || message.type === 'event') return encode(message);
  return JSON.stringify(message);
}

export function parseCommand(message: Record<string, unknown>): CommandMessage | null {
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
