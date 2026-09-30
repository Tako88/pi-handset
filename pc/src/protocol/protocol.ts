/**
 * The attach-protocol envelope and codec.
 *
 * Pure: no I/O, no clock, no randomness. Types are JSON-encodable and use
 * only erasable syntax (no `enum`, `namespace`, or parameter properties).
 *
 * `encode` trusts its typed input; `decode` is the validating boundary.
 * "Never throws" is a `decode`-only guarantee: it catches the `SyntaxError`
 * from malformed JSON and any `RangeError` JSON.parse raises on pathological input.
 */

export const PROTOCOL_VERSION = 1;

/** Fields shared by both `hello` credential shapes. */
export interface HelloBase {
  protocolVersion: number;
  type: 'hello';
}

/** Handshake: a viewer/agent proves itself with a ticket *or* a token, never both. */
export type HelloMessage =
  | (HelloBase & { ticket: string })
  | (HelloBase & { token: string });

/** A token-stream delta, ordered by `seq`. Carried inside an `event`. */
export interface StreamPayload {
  kind: 'stream';
  seq: number;
  text: string;
}

/** The single agent↔hub message, carrying a normalized payload. */
export interface EventMessage {
  protocolVersion: number;
  type: 'event';
  payload: StreamPayload;
}

export type Message = HelloMessage | EventMessage;

/** Machine-readable failure reasons, stable enough for M5 to map and M7 to port. */
export type DecodeErrorCode =
  | 'malformed-json'
  | 'not-an-object'
  | 'bad-version'
  | 'unknown-type'
  | 'bad-credential'
  | 'bad-payload'
  | 'bad-seq'
  | 'bad-text';

export type DecodeResult =
  | { ok: true; value: Message }
  | { ok: false; code: DecodeErrorCode; error: string };

function fail(code: DecodeErrorCode, error: string): DecodeResult {
  return { ok: false, code, error };
}

/** Encodes exactly one JSON object per call. Trusts its typed input. */
export function encode(message: Message): string {
  return JSON.stringify(message);
}

/** Decodes one JSON object, reporting malformed input as a result, never a throw. */
export function decode(text: string): DecodeResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return fail('malformed-json', 'malformed JSON');
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return fail('not-an-object', 'message must be a JSON object');
  }
  const message = parsed as Record<string, unknown>;
  if (message.protocolVersion !== PROTOCOL_VERSION) {
    return fail(
      'bad-version',
      `unsupported protocolVersion: ${String(message.protocolVersion)}`,
    );
  }
  switch (message.type) {
    case 'hello': {
      const hasTicket = message.ticket !== undefined;
      const hasToken = message.token !== undefined;
      if (hasTicket === hasToken) {
        return fail('bad-credential', 'hello must carry exactly one of ticket or token');
      }
      const credential = hasTicket ? message.ticket : message.token;
      if (typeof credential !== 'string' || credential.length === 0) {
        return fail('bad-credential', 'hello credential must be a non-empty string');
      }
      return { ok: true, value: parsed as HelloMessage };
    }
    case 'event': {
      const payload = message.payload;
      if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) {
        return fail('bad-payload', 'event payload must be a JSON object');
      }
      const stream = payload as Record<string, unknown>;
      if (stream.kind !== 'stream') {
        return fail('bad-payload', `unknown event payload kind: ${String(stream.kind)}`);
      }
      const seq = stream.seq;
      if (typeof seq !== 'number' || !Number.isSafeInteger(seq) || seq < 1) {
        return fail('bad-seq', 'stream seq must be a positive safe integer');
      }
      if (typeof stream.text !== 'string') {
        return fail('bad-text', 'stream text must be a string');
      }
      return { ok: true, value: parsed as EventMessage };
    }
    default:
      return fail('unknown-type', `unknown message type: ${String(message.type)}`);
  }
}
