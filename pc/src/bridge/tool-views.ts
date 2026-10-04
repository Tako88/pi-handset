/**
 * Normalized tool views.
 *
 * Every tool result is projected onto the protocol's discriminated `ToolView`
 * union, defensively and totally, then bounded to the view byte cap.
 */

import { TOOL_VIEW_MAX_BYTES, asObject, asString } from '../protocol/protocol.ts';
import type {
  CommandView,
  DiffLine,
  FileView,
  GenericView,
  Match,
  ToolPayload,
  ToolView,
} from '../protocol/protocol.ts';

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
 * The `id` and `name` of one already-objectified tool-call part, or null when
 * either is missing. The single defensive reading of a `toolCall` part, shared
 * by the tool view and the tree label so the two cannot disagree. `type` is
 * checked rather than trusted; a malformed part is skipped, never thrown.
 */
export function toolCallIdentity(
  call: Record<string, unknown> | null,
): { id: string; name: string } | null {
  if (call === null || call.type !== 'toolCall') return null;
  const id = asString(call.id);
  const name = asString(call.name);
  if (id === null || name === null) return null;
  return { id, name };
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
    if (call === null) continue;
    const identity = toolCallIdentity(call);
    if (identity === null) continue;
    const { id, name } = identity;
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
      if (view.content === '') return false;
      const lines = view.content.split('\n');
      view.content = lines.slice(0, Math.floor(lines.length / 2)).join('\n');
      return true;
    }
    case 'command': {
      if (view.output === '') return false;
      const lines = view.output.split('\n');
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

/** The per-scalar byte cap applied to every string field of a bounded view. */
const TOOL_SCALAR_MAX_BYTES = 8 * 1024;

/**
 * Caps a string's UTF-8 byte length to `maxBytes`, keeping the head. Returns
 * the text unchanged when it already fits. Trailing code units are dropped
 * after the byte slice so a split multi-byte character cannot push the result
 * back over the cap.
 */
function capScalarBytes(text: string, maxBytes: number): string {
  if (Buffer.byteLength(text) <= maxBytes) return text;
  let result = Buffer.from(text, 'utf8').subarray(0, maxBytes).toString('utf8');
  while (Buffer.byteLength(result) > maxBytes) result = result.slice(0, -1);
  return result;
}

/** Caps every string field of a view to `TOOL_SCALAR_MAX_BYTES`, in place. */
function boundViewScalars(view: ToolView): void {
  switch (view.type) {
    case 'diff':
      view.path = capScalarBytes(view.path, TOOL_SCALAR_MAX_BYTES);
      return;
    case 'file':
      view.path = capScalarBytes(view.path, TOOL_SCALAR_MAX_BYTES);
      view.content = capScalarBytes(view.content, TOOL_SCALAR_MAX_BYTES);
      return;
    case 'command':
      view.command = capScalarBytes(view.command, TOOL_SCALAR_MAX_BYTES);
      view.output = capScalarBytes(view.output, TOOL_SCALAR_MAX_BYTES);
      return;
    case 'matches':
      for (const match of view.matches) {
        match.file = capScalarBytes(match.file, TOOL_SCALAR_MAX_BYTES);
        match.text = capScalarBytes(match.text, TOOL_SCALAR_MAX_BYTES);
      }
      return;
    case 'table':
      view.columns = view.columns.map((column) => capScalarBytes(column, TOOL_SCALAR_MAX_BYTES));
      view.rows = view.rows.map((row) =>
        row.map((cell) => capScalarBytes(cell, TOOL_SCALAR_MAX_BYTES)),
      );
      return;
    case 'generic':
      if (view.target !== undefined) {
        view.target = capScalarBytes(view.target, TOOL_SCALAR_MAX_BYTES);
      }
      return;
  }
}

/**
 * Bounds one tool payload to `TOOL_VIEW_MAX_BYTES`. `trimToLineCap` runs
 * unconditionally (it mutates only when a cap is actually exceeded), then bulk
 * lines are dropped from the tail until the payload fits, then every view
 * scalar is capped to `TOOL_SCALAR_MAX_BYTES`; anything still over after that
 * becomes a fresh truncated generic marker (a view with many capped scalars,
 * e.g. a table with many long columns). `view.truncated` is set so the app can
 * render its explicit marker. A view already under the cap is returned
 * untouched. The cap is a quarter of the relay budget, deliberately: a relayed
 * frame is dropped whole whenever any byte is outstanding on the viewer, so a
 * payload bounded at the budget itself would be dropped under any backlog.
 */
export function boundToolPayload(payload: ToolPayload): ToolPayload {
  const view = payload.view;
  if (view === undefined) return payload;
  if (trimToLineCap(view)) view.truncated = true;
  const fits = (): boolean => Buffer.byteLength(JSON.stringify(payload)) <= TOOL_VIEW_MAX_BYTES;
  if (fits()) return payload;
  view.truncated = true;
  for (let guard = 0; guard < 64; guard += 1) {
    if (fits()) break;
    if (!dropHalfBulk(view)) break;
  }
  boundViewScalars(view);
  if (!fits()) payload.view = { type: 'generic', truncated: true };
  return payload;
}
