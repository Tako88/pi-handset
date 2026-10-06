/**
 * Tool view builders and payload bounding, exercised through
 * `src/bridge/tool-views.ts`.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  TOOL_VIEW_MAX_BYTES,
  type DiffView,
  type MatchesView,
  type ToolPayload,
} from '../protocol/protocol.ts';
import {
  TOOL_VIEW_MAX_LINES,
  buildToolView,
  toolCallPayloads,
  toolResultPayload,
  boundToolPayload,
} from './tool-views.ts';

// ---------------------------------------------------------------------------
// Tool view builders (M2 — bridge normalization)
// ---------------------------------------------------------------------------

function textContent(text: string): unknown {
  return [{ type: 'text', text }];
}

// --- edit ---

test('buildToolView parses an edit diff from details.diff', () => {
  const view = buildToolView({
    name: 'edit',
    args: { path: 'app/foo.dart', edits: [{ oldText: 'old', newText: 'new' }] },
    content: textContent('Successfully replaced 1 block(s) in app/foo.dart.'),
    details: {
      diff: " 1 void main() {\n-2   print('old');\n+2   print('new');\n 3 }",
      patch: 'ignored',
      firstChangedLine: 2,
    },
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'diff',
    path: 'app/foo.dart',
    lines: [
      { kind: 'ctx', text: 'void main() {' },
      { kind: 'del', text: "  print('old');" },
      { kind: 'add', text: "  print('new');" },
      { kind: 'ctx', text: '}' },
    ],
  });
});

test('an edit view uses details.diff whatever shape input.edits has', () => {
  // pi's `prepareEditArguments` accepts an array, a JSON string of an array, a
  // single object, and a legacy top-level oldText/newText. None of that may
  // matter: the diff is `details.diff` or nothing.
  const details = { diff: '+1 added' };
  const shapes: unknown[] = [
    [{ oldText: 'a', newText: 'b' }],
    JSON.stringify([{ oldText: 'a', newText: 'b' }]),
    { oldText: 'a', newText: 'b' },
    [
      { oldText: 'a', newText: 'b' },
      { oldText: 'c', newText: 'd' },
    ],
  ];
  for (const edits of shapes) {
    const view = buildToolView({
      name: 'edit',
      args: { path: 'a.ts', edits },
      content: textContent('Successfully replaced 1 block(s) in a.ts.'),
      details,
      isError: false,
    });
    assert.deepEqual(
      view,
      { type: 'diff', path: 'a.ts', lines: [{ kind: 'add', text: 'added' }] },
      `edits shape ${JSON.stringify(edits)} must not change the view`,
    );
  }
});

test('an edit without a usable details.diff is generic, never a reconstructed diff', () => {
  for (const details of [undefined, {}, { diff: '' }, { diff: 42 }]) {
    const view = buildToolView({
      name: 'edit',
      args: { path: 'a.ts', edits: [{ oldText: 'old', newText: 'new' }] },
      content: textContent('Successfully replaced 1 block(s) in a.ts.'),
      details: details,
      isError: false,
    });
    assert.equal(view.type, 'generic');
    assert.equal((view).target, 'a.ts');
  }
});

// --- write ---

test('a write view is an all-addition diff claiming no line delta', () => {
  const view = buildToolView({
    name: 'write',
    args: { path: 'app/new.dart', content: 'line one\nline two\n' },
    content: textContent('Successfully wrote to app/new.dart'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'diff',
    path: 'app/new.dart',
    lines: [
      { kind: 'add', text: 'line one' },
      { kind: 'add', text: 'line two' },
    ],
  });
  // There is no old file to diff against, so no `+N −M` line delta may be
  // fabricated anywhere in the view. (The one-line summary is app-side; this
  // pins the bridge half of the rule.)
  assert.doesNotMatch(JSON.stringify(view), /[+−]\d/);
});

test('a write of empty content is a diff view with zero lines', () => {
  const view = buildToolView({
    name: 'write',
    args: { path: 'empty.txt', content: '' },
    content: textContent('Successfully wrote to empty.txt'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, { type: 'diff', path: 'empty.txt', lines: [] });
});

// --- read ---

test('a read view carries the path, content and the requested range', () => {
  const view = buildToolView({
    name: 'read',
    args: { path: 'app/foo.dart', offset: 2, limit: 3 },
    content: textContent('line two\nline three\nline four'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'file',
    path: 'app/foo.dart',
    content: 'line two\nline three\nline four',
    startLine: 2,
    endLine: 4,
  });
});

test('a read stopped by the user limit derives its range from input.offset/limit', () => {
  const view = buildToolView({
    name: 'read',
    args: { path: 'big.ts', limit: 3 },
    content: textContent('line one\n\n[3 more lines in file. Use offset=4 to continue.]'),
    details: undefined,
    isError: false,
  });
  assert.equal(view.type, 'file');
  assert.equal((view).startLine, 1);
  assert.equal((view).endLine, 3);
});

test('a pi-truncated read derives its range from the continuation notice', () => {
  const view = buildToolView({
    name: 'read',
    args: { path: 'big.ts' },
    content: textContent('line 10\nline 11\n\n[Showing lines 10-11 of 100. Use offset=12 to continue.]'),
    details: { truncation: { truncated: true } },
    isError: false,
  });
  assert.equal(view.type, 'file');
  assert.equal((view).startLine, 10);
  assert.equal((view).endLine, 11);
});

test('an image read is generic, never a text file view', () => {
  const view = buildToolView({
    name: 'read',
    args: { path: 'pic.png' },
    content: [
      { type: 'text', text: 'Read image file [image/png]' },
      { type: 'image', data: 'AAAA', mimeType: 'image/png' },
    ],
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, { type: 'generic', target: 'pic.png' });
});

// --- bash ---

test('a successful bash view shows the command, merged output and exit 0', () => {
  const view = buildToolView({
    name: 'bash',
    args: { command: 'ls -1' },
    content: textContent('README.md\npackage.json\n'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'command',
    command: 'ls -1',
    output: 'README.md\npackage.json\n',
    exitCode: 0,
  });
});

test('a bash failure parses exitCode only from a trailing Command exited with code N', () => {
  const view = buildToolView({
    name: 'bash',
    args: { command: 'false' },
    content: textContent('some output\n\nCommand exited with code 3'),
    details: undefined,
    isError: true,
  });
  assert.equal(view.type, 'command');
  assert.equal((view).exitCode, 3);
});

test('aborted, timed-out and signalled bash carry no exit code', () => {
  const texts = [
    'Command aborted',
    'output\n\nCommand timed out after 12 seconds',
    'output\n\nCommand terminated without an exit code',
  ];
  for (const text of texts) {
    const view = buildToolView({
      name: 'bash',
      args: { command: 'sleep 99' },
      content: textContent(text),
      details: undefined,
      isError: true,
    });
    assert.equal(view.type, 'command');
    assert.equal((view).exitCode, undefined, `${text} must not yield a code`);
  }
});

// --- grep ---

test('a grep view flattens match and context lines into file/line/text', () => {
  const view = buildToolView({
    name: 'grep',
    args: { pattern: 'print' },
    content: textContent(
      'src/a.ts:12: const x = 1;\nsrc/a.ts-13- const y = 2;\nsrc/b.ts:4: other;',
    ),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'matches',
    matches: [
      { file: 'src/a.ts', line: 12, text: 'const x = 1;' },
      { file: 'src/a.ts', line: 13, text: 'const y = 2;' },
      { file: 'src/b.ts', line: 4, text: 'other;' },
    ],
  });
});

test('grep paths containing a colon or a Windows drive parse correctly', () => {
  const view = buildToolView({
    name: 'grep',
    args: { pattern: 'x' },
    content: textContent('src/a:b.ts:12: text\nC:\\proj\\a.ts:7: win'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual((view as MatchesView).matches, [
    { file: 'src/a:b.ts', line: 12, text: 'text' },
    { file: 'C:\\proj\\a.ts', line: 7, text: 'win' },
  ]);
});

test('a grep body containing a further line-number pattern does not steal it', () => {
  const view = buildToolView({
    name: 'grep',
    args: { pattern: 'x' },
    content: textContent(
      "src/a.ts:12: const s = ': 34: x';\nsrc/a.ts:12: see foo:34: here",
    ),
    details: undefined,
    isError: false,
  });
  // The path is the non-greedy prefix and the first `:N: ` wins; a greedy path
  // would consume up to the trailing `:34:` and report line 34.
  assert.deepEqual((view as MatchesView).matches, [
    { file: 'src/a.ts', line: 12, text: "const s = ': 34: x';" },
    { file: 'src/a.ts', line: 12, text: 'see foo:34: here' },
  ]);
});

test('grep drops notice lines and yields an empty view for No matches found', () => {
  const withNotice = buildToolView({
    name: 'grep',
    args: { pattern: 'x' },
    content: textContent(
      'src/a.ts:1: hit\n\n[100 matches limit reached. Use limit=200 for more, or refine pattern]',
    ),
    details: { matchLimitReached: 100 },
    isError: false,
  });
  assert.deepEqual((withNotice as MatchesView).matches, [
    { file: 'src/a.ts', line: 1, text: 'hit' },
  ]);

  const empty = buildToolView({
    name: 'grep',
    args: { pattern: 'x' },
    content: textContent('No matches found'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(empty, { type: 'matches', matches: [] });
});

// --- find ---

test('a find view lists matching files and yields an empty view for a miss', () => {
  const view = buildToolView({
    name: 'find',
    args: { pattern: '*.ts' },
    content: textContent('src/a.ts\nsrc/b.ts'),
    details: undefined,
    isError: false,
  });
  // find reuses the matches view: a file match has no line, so line 0 and empty
  // text mark it (there is no dedicated files view in the contract).
  assert.deepEqual((view as MatchesView).matches, [
    { file: 'src/a.ts', line: 0, text: '' },
    { file: 'src/b.ts', line: 0, text: '' },
  ]);
  const empty = buildToolView({
    name: 'find',
    args: { pattern: '*.ts' },
    content: textContent('No files found matching pattern'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(empty, { type: 'matches', matches: [] });
});

// --- ls ---

test('an ls view is a name/type table', () => {
  const view = buildToolView({
    name: 'ls',
    args: { path: '.' },
    content: textContent('app/\nREADME.md\n.gitignore'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, {
    type: 'table',
    columns: ['name', 'type'],
    rows: [
      ['app', 'directory'],
      ['README.md', 'file'],
      ['.gitignore', 'file'],
    ],
  });
});

test('an empty directory is an empty table, not generic', () => {
  const view = buildToolView({
    name: 'ls',
    args: { path: 'empty' },
    content: textContent('(empty directory)'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(view, { type: 'table', columns: ['name', 'type'], rows: [] });
});

// --- generic ---

test('a custom tool falls back to a generic view carrying its target', () => {
  const withPath = buildToolView({
    name: 'my-tool',
    args: { path: 'x.ts', other: 1 },
    content: textContent('did the thing'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(withPath, { type: 'generic', target: 'x.ts' });

  const bare = buildToolView({
    name: 'my-tool',
    args: {},
    content: textContent('x'),
    details: undefined,
    isError: false,
  });
  assert.deepEqual(bare, { type: 'generic' });
});

// ---------------------------------------------------------------------------
// Payload construction and bounding
// ---------------------------------------------------------------------------

test('toolCallPayloads builds a running payload (and an input-only write diff)', () => {
  const message = {
    role: 'assistant',
    content: [
      { type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'a.ts' } },
      { type: 'toolCall', id: 'call-2', name: 'write', arguments: { path: 'b.ts', content: 'x' } },
    ],
  };
  const payloads = toolCallPayloads(message, new Map());
  assert.deepEqual(payloads, [
    { kind: 'tool', toolCallId: 'call-1', name: 'read', status: 'running', view: { type: 'generic', target: 'a.ts' } },
    { kind: 'tool', toolCallId: 'call-2', name: 'write', status: 'running', view: { type: 'diff', path: 'b.ts', lines: [{ kind: 'add', text: 'x' }] } },
  ]);
});

test('toolResultPayload builds a done/error payload from the full view', () => {
  const done = toolResultPayload(
    {
      role: 'toolResult',
      toolCallId: 'call-1',
      toolName: 'read',
      content: [{ type: 'text', text: 'body' }],
      isError: false,
    },
    new Map([['call-1', { path: 'a.ts' }]]),
  );
  assert.deepEqual(done, {
    kind: 'tool',
    toolCallId: 'call-1',
    name: 'read',
    status: 'done',
    view: { type: 'file', path: 'a.ts', content: 'body' },
  });

  const errored = toolResultPayload(
    {
      role: 'toolResult',
      toolCallId: 'call-2',
      toolName: 'bash',
      content: [{ type: 'text', text: 'boom' }],
      isError: true,
    },
    new Map([['call-2', { command: 'false' }]]),
  );
  assert.equal(errored!.status, 'error');
  assert.deepEqual(errored!.view, { type: 'command', command: 'false', output: 'boom' });
});

test('boundToolPayload trims a bulk view to TOOL_VIEW_MAX_BYTES and flags it', () => {
  const lines = Array.from({ length: 5000 }, (_value, index) => ({
    kind: 'add' as const,
    text: `line ${index} ${'x'.repeat(40)}`,
  }));
  const payload: ToolPayload = {
    kind: 'tool',
    toolCallId: 'c1',
    name: 'edit',
    status: 'done',
    view: { type: 'diff', path: 'big.txt', lines },
  };
  const bounded = boundToolPayload(payload);
  assert.ok(Buffer.byteLength(JSON.stringify(bounded)) <= TOOL_VIEW_MAX_BYTES);
  assert.equal(bounded.view!.truncated, true);
  assert.ok((bounded.view as DiffView).lines.length < 5000);
  assert.ok((bounded.view as DiffView).lines.length > 0);
  assert.ok((bounded.view as DiffView).lines.length <= TOOL_VIEW_MAX_LINES);
});

test('boundToolPayload leaves an under-cap view untouched', () => {
  const payload: ToolPayload = {
    kind: 'tool',
    toolCallId: 'c1',
    name: 'edit',
    status: 'done',
    view: { type: 'diff', path: 'a', lines: [{ kind: 'add', text: 'x' }] },
  };
  const bounded = boundToolPayload(payload);
  assert.deepEqual(bounded, payload);
  assert.equal(bounded.view!.truncated, undefined);
});

test('boundToolPayload flags a view trimmed purely by the line cap', () => {
  const lines = Array.from({ length: 2500 }, () => ({ kind: 'add' as const, text: 'x' }));
  const payload: ToolPayload = {
    kind: 'tool',
    toolCallId: 'c1',
    name: 'edit',
    status: 'done',
    view: { type: 'diff', path: 'a', lines },
  };
  // Precondition: under the byte cap, so only the line cap can trigger a trim.
  assert.ok(Buffer.byteLength(JSON.stringify(payload)) <= TOOL_VIEW_MAX_BYTES);
  const bounded = boundToolPayload(payload);
  assert.equal((bounded.view as DiffView).lines.length, TOOL_VIEW_MAX_LINES);
  assert.equal(bounded.view!.truncated, true);
});

test('every adversarial tool payload is bounded to TOOL_VIEW_MAX_BYTES', () => {
  const long = 'x'.repeat(200_000);
  const payloads: ToolPayload[] = [
    { kind: 'tool', toolCallId: 'c1', name: 'custom', status: 'done', view: { type: 'generic', target: long } },
    { kind: 'tool', toolCallId: 'c2', name: 'bash', status: 'done', view: { type: 'command', command: long, output: '' } },
    { kind: 'tool', toolCallId: 'c3', name: 'edit', status: 'done', view: { type: 'diff', path: long, lines: [] } },
    { kind: 'tool', toolCallId: 'c4', name: 'read', status: 'done', view: { type: 'file', path: long, content: '' } },
    { kind: 'tool', toolCallId: 'c5', name: 'ls', status: 'done', view: { type: 'table', columns: [long], rows: [] } },
  ];
  for (const payload of payloads) {
    const bounded = boundToolPayload(payload);
    assert.ok(
      Buffer.byteLength(JSON.stringify(bounded)) <= TOOL_VIEW_MAX_BYTES,
      `${payload.name} exceeded TOOL_VIEW_MAX_BYTES`,
    );
  }
});

test('a view whose scalars cannot all fit becomes a fresh truncated generic marker with identity intact', () => {
  const column = 'x'.repeat(20_000);
  const payload: ToolPayload = {
    kind: 'tool',
    toolCallId: 'c1',
    name: 'ls',
    status: 'done',
    view: { type: 'table', columns: Array.from({ length: 20 }, () => column), rows: [] },
  };
  const bounded = boundToolPayload(payload);
  assert.ok(Buffer.byteLength(JSON.stringify(bounded)) <= TOOL_VIEW_MAX_BYTES);
  assert.equal(bounded.view!.type, 'generic');
  assert.equal(bounded.view!.truncated, true);
  assert.equal(bounded.toolCallId, 'c1');
  assert.equal(bounded.name, 'ls');
  assert.equal(bounded.status, 'done');
  assert.equal(bounded.kind, 'tool');
});

test('a scalar-only overflow is capped in place without failing closed', () => {
  const payload: ToolPayload = {
    kind: 'tool',
    toolCallId: 'c1',
    name: 'read',
    status: 'done',
    view: { type: 'file', path: 'x'.repeat(200_000), content: '' },
  };
  const bounded = boundToolPayload(payload);
  assert.ok(Buffer.byteLength(JSON.stringify(bounded)) <= TOOL_VIEW_MAX_BYTES);
  assert.equal(bounded.view!.type, 'file');
  assert.equal(bounded.view!.truncated, true);
});

test('boundToolPayload leaves a viewless payload untouched', () => {
  const payload: ToolPayload = {
    kind: 'tool',
    toolCallId: 'c1',
    name: 'read',
    status: 'done',
  };
  const bounded = boundToolPayload(payload);
  assert.deepEqual(bounded, payload);
});
