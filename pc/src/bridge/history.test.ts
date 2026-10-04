/**
 * History and session-tree projection, exercised through
 * `src/bridge/history.ts`.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  HISTORY_MAX_BYTES,
  PROTOCOL_VERSION,
  TOOL_VIEW_MAX_BYTES,
  type TreeNodeSummary,
  type ToolPayload,
} from '../protocol/protocol.ts';
import {
  projectHistory,
  entryAnchor,
  mintCursor,
  annotateToolViews,
  projectTree,
} from './history.ts';
import {
  makeHarness,
  parsed,
  sendCommand,
  type FakeSocket,
} from '../../test/support/bridge-harness.ts';

test('listTree projects the real session tree into relinked, role-tagged nodes', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setTree([
    {
      entry: { type: 'message', id: 'u1', message: { role: 'user', content: 'first' } },
      children: [
        {
          entry: { type: 'compaction', id: 'c1' },
          children: [
            {
              entry: {
                type: 'message',
                id: 'u2',
                message: {
                  role: 'user',
                  content: [
                    { type: 'text', text: 'second ' },
                    { type: 'image', data: 'AAAA' },
                  ],
                },
              },
              children: [
                {
                  entry: {
                    type: 'message',
                    id: 'a1',
                    message: { role: 'assistant', content: [{ type: 'toolCall', id: 't1' }] },
                  },
                  children: [
                    {
                      entry: {
                        type: 'message',
                        id: 'tr1',
                        message: { role: 'toolResult', toolCallId: 't1', content: [] },
                      },
                      children: [
                        {
                          entry: { type: 'message', id: 'u3', message: { role: 'user', content: 'third' } },
                          children: [],
                        },
                      ],
                    },
                  ],
                },
                // A malformed node: entry.message is missing. Skipped, never
                // thrown; the projection is called inside dispatch, where a
                // throw would surface as a generic refusal.
                { entry: { type: 'message', id: 'bad' }, children: [] },
              ],
            },
          ],
        },
      ],
    },
  ]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1) as {
    ok: boolean;
    tree: TreeNodeSummary[];
    treeTruncated: boolean;
  };
  assert.equal(result.ok, true);
  // Non-message entries are traversed but not emitted, and a message node's
  // parent is its nearest EMITTED ancestor — so u2 relinks past the compaction
  // to u1, and u3 relinks past the toolResult to a1.
  assert.deepEqual(result.tree, [
    { id: 'u1', parentId: null, role: 'user', text: 'first' },
    { id: 'u2', parentId: 'u1', role: 'user', text: 'second [image]' },
    { id: 'a1', parentId: 'u2', role: 'assistant', text: '' },
    { id: 'u3', parentId: 'a1', role: 'user', text: 'third' },
  ]);
  assert.equal(result.treeTruncated, false);
});

/** The projected text of one message node, via the real tree projection. */
function treeTextFor(role: 'user' | 'assistant', content: unknown): string {
  const { nodes } = projectTree([
    { entry: { type: 'message', id: 'n1', message: { role, content } }, children: [] },
  ]);
  return nodes[0]?.text ?? '<missing node>';
}

test('an assistant turn with thinking and tool calls is labelled by its tool names', () => {
  // A turn that ran tools before writing any prose used to project to an empty
  // string and read as "(empty message)" in the app. It is labelled by the
  // tools that ran instead — pi labels such rows the same way.
  const text = treeTextFor('assistant', [
    { type: 'thinking', thinking: 'let me look' },
    { type: 'toolCall', id: 't1', name: 'ls', arguments: {} },
    { type: 'toolCall', id: 't2', name: 'grep', arguments: {} },
  ]);
  assert.equal(text, '(tool calls: ls, grep)');
});

test('repeated tool names are deduplicated in first-seen order', () => {
  const text = treeTextFor('assistant', [
    { type: 'toolCall', id: 't1', name: 'ls' },
    { type: 'toolCall', id: 't2', name: 'grep' },
    { type: 'toolCall', id: 't3', name: 'ls' },
  ]);
  assert.equal(text, '(tool calls: ls, grep)');
});

test('a thinking-only assistant turn is labelled (thinking)', () => {
  const text = treeTextFor('assistant', [{ type: 'thinking', thinking: 'hmm' }]);
  assert.equal(text, '(thinking)');
});

test('an assistant turn with text is unchanged by the empty-turn fallback', () => {
  // The fallback is for the empty case ONLY: a text-bearing turn must not gain
  // a tool-name suffix and must not lose its text.
  const text = treeTextFor('assistant', [
    { type: 'thinking', thinking: 'hmm' },
    { type: 'text', text: 'done' },
    { type: 'toolCall', id: 't1', name: 'ls' },
  ]);
  assert.equal(text, 'done');
});

test("a user message's projection is unchanged, image markers and all", () => {
  const text = treeTextFor('user', [
    { type: 'text', text: 'look ' },
    { type: 'image', data: 'AAAA' },
    { type: 'text', text: ' here' },
  ]);
  assert.equal(text, 'look [image] here');
});

test('listTree keeps the newest 200 nodes and repairs the dangling parent', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  let chain: unknown[] = [];
  for (let index = 204; index >= 0; index -= 1) {
    chain = [
      {
        entry: { type: 'message', id: `n${index}`, message: { role: 'user', content: `m${index}` } },
        children: chain,
      },
    ];
  }
  ctx.setTree(chain);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1) as {
    tree: TreeNodeSummary[];
    treeTruncated: boolean;
  };
  assert.equal(result.treeTruncated, true);
  assert.equal(result.tree.length, 200);
  assert.equal(result.tree[0]!.id, 'n5');
  // n5's parent (n4) was dropped, so it must not point at a missing id.
  assert.equal(result.tree[0]!.parentId, null);
  assert.equal(result.tree.at(-1)!.id, 'n204');
});

test('listTree refuses when pi has no getTree', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  delete (ctx.sessionManager as { getTree?: unknown }).getTree;
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1) as { ok: boolean; error?: string };
  assert.equal(result.ok, false);
  assert.equal(result.error, 'tree unavailable');
});

test('listTree projects an empty tree as no nodes and not truncated', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  // A fresh session legitimately has no message entries yet — that is an empty
  // picker, never an error and never a truncation.
  ctx.setTree([]);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1) as {
    ok: boolean;
    tree: unknown[];
    treeTruncated: boolean;
  };
  assert.equal(result.ok, true);
  assert.deepEqual(result.tree, []);
  assert.equal(result.treeTruncated, false);
});

test('listTree carries the current leaf id', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setLeafId('t1');
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1)!;
  assert.ok('leafId' in result, 'the listTree result must carry leafId');
  assert.equal(result.leafId, 't1');
});

test('listTree reports a null leaf when there is none', async () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setLeafId(null);
  const socket = harness.sockets[0]!;
  socket.open();
  await sendCommand(harness.pi, socket, 'listTree');
  const result = parsed(socket).at(-1)!;
  // The key must be present and explicitly null: absent means "an older
  // bridge", which the app cannot tell from "at the root".
  assert.ok('leafId' in result, 'the listTree result must carry leafId');
  assert.equal(result.leafId, null);
});

// ---------------------------------------------------------------------------
// History projection
// ---------------------------------------------------------------------------

test('projectHistory keeps the newest entries when it truncates', () => {
  const entries = Array.from({ length: 100 }, (_value, index) => ({ id: index, text: 'x'.repeat(200) }));
  const projection = projectHistory(entries, 1024);
  assert.equal(projection.truncated, true);
  assert.ok(Buffer.byteLength(JSON.stringify(projection.entries)) <= 1024);
  assert.deepEqual(
    projection.entries.at(-1),
    entries.at(-1),
    'the newest entry must survive: a re-subscribe replays this window',
  );
  assert.ok(
    !projection.entries.includes(entries[0]),
    'the oldest entry is the one to drop',
  );
  // Order is chronological: the app appends these as later rows.
  const ids = projection.entries.map((entry) => (entry as { id: number }).id);
  assert.deepEqual(ids, [...ids].sort((a, b) => a - b));
});

test('projectHistory collapses an entry too large to ever fit, and keeps walking', () => {
  const huge = { id: 'huge', text: 'x'.repeat(4096) };
  const entries = [{ id: 'old' }, huge, { id: 'new' }];
  const projection = projectHistory(entries, 2048);
  assert.equal(
    projection.truncated,
    false,
    'the giant is collapsed, not dropped, so no older entry is omitted',
  );
  assert.deepEqual(projection.entries[0], { id: 'old' });
  assert.deepEqual(projection.entries[1], {
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(huge)),
  });
  assert.deepEqual(projection.entries[2], { id: 'new' });
  assert.ok(Buffer.byteLength(JSON.stringify(projection.entries)) <= 2048);
});

test('an oversized history entry with an image keeps its text', () => {
  const image = { type: 'image', data: 'A'.repeat(4096) };
  const entry = {
    type: 'message',
    message: { role: 'user', content: [{ type: 'text', text: 'hi' }, image] },
  };
  const projection = projectHistory([entry], 2048);
  assert.equal(projection.entries.length, 1);
  const kept = projection.entries[0] as { message?: { content?: unknown[] } };
  // Not the whole-entry marker: the trim rescued it and rebuilt the wrapper.
  assert.notDeepEqual(kept, { truncated: true, bytes: Buffer.byteLength(JSON.stringify(entry)) });
  assert.deepEqual(kept.message?.content?.[0], { type: 'text', text: 'hi' });
  assert.deepEqual(kept.message?.content?.[1], {
    type: 'image',
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(image)),
  });
});

// PIN: green today. NC-8 omits the marker fallback before the `break`.
test('a trimmed history entry that still does not fit the window falls back to the marker and the walk continues', () => {
  const smallOld = { id: 'old' };
  const smallNewest = { id: 'new', text: 'n'.repeat(600) };
  const bigImageMsg = {
    role: 'user',
    content: [{ type: 'text', text: 't'.repeat(1500) }, { type: 'image', data: 'A'.repeat(5000) }],
  };
  const projection = projectHistory([smallOld, bigImageMsg, smallNewest], 2048);
  // The trim fits the entry on its own, but not the *remaining* window after the
  // newest entry. The marker fallback must run before the break so the older
  // entry survives and the window flag stays false.
  assert.equal(projection.truncated, false);
  assert.deepEqual(projection.entries[0], smallOld);
  assert.deepEqual(projection.entries[1], {
    truncated: true,
    bytes: Buffer.byteLength(JSON.stringify(bigImageMsg)),
  });
  assert.deepEqual(projection.entries[2], smallNewest);
});

test('projectHistory collapses a giant even when it is the newest entry', () => {
  const huge = { id: 'huge', text: 'x'.repeat(4096) };
  const projection = projectHistory([{ id: 'old' }, huge], 2048);
  assert.equal(projection.truncated, false);
  assert.deepEqual(projection.entries, [
    { id: 'old' },
    { truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) },
  ]);

  // Only the giant: the window may then hold exactly one marker, and the
  // comma term must not be charged for it.
  const alone = projectHistory([huge], 2048);
  assert.deepEqual(alone, {
    entries: [{ truncated: true, bytes: Buffer.byteLength(JSON.stringify(huge)) }],
    truncated: false,
    start: 0,
  });
});

test('projectHistory truncates at the byte cap and flags it', () => {
  const entries = Array.from({ length: 100 }, (_value, index) => ({ id: index, text: 'x'.repeat(200) }));
  const projection = projectHistory(entries, 1024);
  assert.equal(projection.truncated, true);
  assert.ok(Buffer.byteLength(JSON.stringify(projection.entries)) <= 1024);
  assert.ok(projection.entries.length < entries.length);
});

test('projectHistory keeps everything under the cap', () => {
  const entries = [{ id: 1 }, { id: 2 }];
  const projection = projectHistory(entries, 1024);
  assert.deepEqual(projection, { entries, truncated: false, start: 0 });
});

test('projectHistory pages an older window up to the given end', () => {
  const entries = Array.from({ length: 100 }, (_value, index) => ({ id: index, text: 'x'.repeat(200) }));
  const page = projectHistory(entries, 1024, 60);
  assert.ok(page.start > 0, 'the page must start inside the bounded prefix');
  assert.ok(page.start < 60, 'the page must not reach past the given end');
  assert.deepEqual(page.entries, entries.slice(page.start, 60));
  assert.equal(page.truncated, true);
  assert.ok(page.entries.every((entry) => (entry as { id: number }).id < 60));
});

test('projectHistory pages from the beginning when end is 0', () => {
  const entries = [{ id: 1 }, { id: 2 }];
  assert.deepEqual(projectHistory(entries, 1024, 0), {
    entries: [],
    truncated: false,
    start: 0,
  });
});

test('pages concatenated oldest-first reconstruct the whole annotated array', () => {
  const annotated = Array.from({ length: 50 }, (_value, index) => ({
    id: index,
    text: `t${index}`,
    pad: 'x'.repeat(30),
  }));
  const budget = 200;
  const pages: unknown[][] = [];
  let end = annotated.length;
  for (let guard = 0; guard < 64; guard += 1) {
    const page = projectHistory(annotated, budget, end);
    pages.unshift(page.entries);
    if (page.start === 0) break;
    end = page.start;
    if (guard === 63) assert.fail('projectHistory never reached the beginning');
  }
  assert.deepEqual(pages.flat(), annotated);
});

/** The newest `history` frame a socket has sent. */
function lastHistory(socket: FakeSocket): Record<string, unknown> {
  const history = parsed(socket)
    .filter((message) => message.type === 'history')
    .at(-1);
  assert.ok(history, 'expected a history frame');
  return history;
}

/** Plain user-message entries large enough that a page cannot hold them all. */
function largeEntries(count: number, chars: number): unknown[] {
  return Array.from({ length: count }, (_value, index) => ({
    type: 'message',
    id: `e${index}`,
    message: { role: 'user', content: `${index}:${'x'.repeat(chars)}` },
  }));
}

test('a history-request with a cursor answers an older page, echoes the cursor and marks it older', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setEntries(largeEntries(6, 200_000));
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId: 'sess-1' });
  const baseline = lastHistory(socket);
  const cursor = baseline.olderCursor;
  assert.equal(typeof cursor, 'string', 'the baseline must offer a next cursor');
  assert.equal('cursor' in baseline, false);
  assert.equal('older' in baseline, false);
  const offset = Number((cursor as string).split(':')[0]);
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
    cursor,
  });
  const page = lastHistory(socket);
  assert.equal(page.cursor, cursor);
  assert.equal(page.older, true);
  assert.deepEqual(page.entries, annotateToolViews(largeEntries(6, 200_000)).slice(0, offset));
  assert.equal('olderCursor' in page, false, 'the beginning is reached in one more page');
});

test('a mismatched anchor answers a fresh baseline carrying the routing cursor but no older flag', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setEntries(largeEntries(6, 200_000));
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId: 'sess-1' });
  const baseline = lastHistory(socket);
  const offset = (baseline.olderCursor as string).split(':')[0];
  const wrong = `${offset}:0000000000000000`;
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
    cursor: wrong,
  });
  const page = lastHistory(socket);
  assert.equal(page.cursor, wrong, 'the routing token is echoed even when not honoured');
  assert.equal('older' in page, false);
  assert.deepEqual(page.entries, baseline.entries, 'a mismatch degrades to a fresh newest page');
});

test('a history frame carries olderCursor only when older entries remain', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setEntries(largeEntries(10, 200_000));
  const socket = harness.sockets[0]!;
  socket.open();
  let cursor: string | undefined;
  let sawIntermediate = false;
  for (let guard = 0; guard < 64; guard += 1) {
    socket.message({
      protocolVersion: PROTOCOL_VERSION,
      type: 'history-request',
      sessionId: 'sess-1',
      ...(cursor === undefined ? {} : { cursor }),
    });
    const history = lastHistory(socket);
    if (history.olderCursor === undefined) {
      assert.ok(sawIntermediate, 'expected at least one intermediate page with an olderCursor');
      return;
    }
    sawIntermediate = true;
    cursor = history.olderCursor as string;
  }
  assert.fail('history paging never reached the beginning in 64 pages');
});

// PIN: a no-cursor request is byte-identical to today (NC-4 keeps this green).
test('a history-request without a cursor is byte-identical to today', () => {
  const harness = makeHarness();
  harness.start();
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId: 'sess-1' });
  assert.deepEqual(lastHistory(socket), {
    protocolVersion: PROTOCOL_VERSION,
    type: 'history',
    sessionId: 'sess-1',
    entries: [{ type: 'message', id: 'e1' }],
    truncated: false,
  });
});

test('a cursor whose boundary entry was collapsed still revalidates and pages the older window', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const sizeOf = (value: unknown): number => Buffer.byteLength(JSON.stringify(value) ?? 'null');
  const huge = {
    type: 'message',
    id: 'huge',
    message: { role: 'user', content: `H${'x'.repeat(900_000)}` },
  };
  // Tune the newest entry so the budget is nearly spent by the time the walk
  // reaches `huge`; its tiny marker is kept, then the next-older entry no
  // longer fits. The boundary is the collapsed `huge`, not the newest entry.
  const newestTarget = HISTORY_MAX_BYTES - sizeOf({ truncated: true, bytes: sizeOf(huge) }) - 20;
  const newestBase = { type: 'message', id: 'new', message: { role: 'user', content: '' } };
  const newest = {
    type: 'message',
    id: 'new',
    message: { role: 'user', content: 'n'.repeat(newestTarget - sizeOf(newestBase)) },
  };
  assert.equal(sizeOf(newest), newestTarget);
  const older = { type: 'message', id: 'old', message: { role: 'user', content: 'older' } };
  ctx.setEntries([older, huge, newest]);
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId: 'sess-1' });
  const baseline = lastHistory(socket);
  const cursor = baseline.olderCursor;
  assert.equal(typeof cursor, 'string', 'the baseline must carry an olderCursor; the fixture is mistuned');
  // The delivered boundary is the substituted marker, but the anchor digests
  // the original entry, so the cursor must still revalidate.
  assert.deepEqual((baseline.entries as unknown[])[0], { truncated: true, bytes: sizeOf(huge) });
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
    cursor,
  });
  const page = lastHistory(socket);
  assert.equal(page.cursor, cursor);
  assert.equal(page.older, true);
  assert.deepEqual(page.entries, [older], 'the page must be the strictly older window');
  assert.equal('olderCursor' in page, false);
});

test('the anchor binds the offset, so identical entries at different offsets do not alias', () => {
  const shared = { type: 'message', id: 'same', message: { role: 'user', content: 'same' } };
  const annotated = [shared, shared];
  assert.notEqual(mintCursor(annotated, 0), mintCursor(annotated, 1));
  // The digest itself, not just mintCursor's index prefix, must bind the offset.
  assert.notEqual(entryAnchor(0, shared), entryAnchor(1, shared));
  // The offset was swapped onto the other identical entry's anchor: a
  // content-only digest would validate it, an offset-bound one must not.
  const swapped = `0:${mintCursor(annotated, 1).split(':')[1]!}`;
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setEntries(annotated);
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
    cursor: swapped,
  });
  const history = lastHistory(socket);
  assert.equal('older' in history, false);
});

test('a history-request with an unparseable cursor answers a baseline without throwing', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  ctx.setEntries(largeEntries(6, 200_000));
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId: 'sess-1' });
  const baseline = lastHistory(socket);
  assert.doesNotThrow(() => {
    socket.message({
      protocolVersion: PROTOCOL_VERSION,
      type: 'history-request',
      sessionId: 'sess-1',
      cursor: 'not-a-cursor',
    });
  });
  const page = lastHistory(socket);
  assert.equal(page.cursor, 'not-a-cursor', 'the routing token is echoed even when unparseable');
  assert.equal('older' in page, false);
  assert.deepEqual(page.entries, baseline.entries, 'an unparseable cursor degrades to the newest page');
});

test('a history-request with an out-of-range offset degrades to a baseline', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const entries = largeEntries(6, 200_000);
  ctx.setEntries(entries);
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId: 'sess-1' });
  const baseline = lastHistory(socket);
  const annotated = annotateToolViews(entries);
  const offset = 999;
  assert.ok(offset >= annotated.length, 'the fixture must place the offset past the annotated array');
  // The anchor is the digest production computes at that out-of-range offset, so
  // the range check -- not the anchor comparison -- is the only thing that can
  // reject this cursor. Without the range check the walk emits `undefined`.
  const cursor = `${offset}:${entryAnchor(offset, annotated[offset])}`;
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
    cursor,
  });
  const page = lastHistory(socket);
  assert.equal(page.cursor, cursor, 'the routing token is echoed even when out of range');
  assert.equal('older' in page, false);
  assert.deepEqual(page.entries, baseline.entries, 'an out-of-range offset degrades to the newest page');
});

/** A user entry whose serialized JSON is exactly `target` bytes, so a paging
 * fixture can be tuned to the byte. */
function paddedEntry(id: string, target: number): Record<string, unknown> {
  const entry: Record<string, unknown> = { type: 'message', id, message: { role: 'user', content: '' } };
  let content = '';
  for (let guard = 0; guard < 6; guard += 1) {
    (entry.message as { content: string }).content = content;
    const delta = target - Buffer.byteLength(JSON.stringify(entry));
    if (delta === 0) return entry;
    assert.ok(delta > 0, 'paddedEntry must grow toward its target');
    content += 'x'.repeat(delta);
  }
  throw new Error('paddedEntry did not converge');
}

test('the anchor revalidates over tool-annotated entries', () => {
  const harness = makeHarness();
  const ctx = harness.start();
  const call = {
    type: 'message',
    id: 'a1',
    message: {
      role: 'assistant',
      content: [{ type: 'toolCall', id: 'call-1', name: 'customtool', arguments: {} }],
    },
  };
  const result = {
    type: 'message',
    id: 'r1',
    message: {
      role: 'toolResult',
      toolCallId: 'call-1',
      toolName: 'customtool',
      content: 'done',
      isError: false,
    },
  };
  const prefix = annotateToolViews([call, result]);
  assert.equal(prefix.length, 4, 'the fixture must synthesize one payload per tool frame');
  const sizeOf = (value: unknown): number => Buffer.byteLength(JSON.stringify(value) ?? 'null');
  const sizeDone = sizeOf(prefix[3]);
  const sizeResult = sizeOf(prefix[2]);
  // Tune the two fillers so the newest page holds the tool-result's synthetic
  // payload (index 3) and stops at the tool result (index 2): the cursor's
  // anchor then points at a SYNTHETIC payload, and the whole older prefix fits,
  // so the honoured page is an exact slice of the annotated array.
  const margin = 60;
  assert.ok(sizeResult + 3 > margin, 'the tool result must be large enough to stop the walk');
  const fillerTotal = HISTORY_MAX_BYTES - margin - 5 - sizeDone;
  const newer = paddedEntry('f1', Math.floor(fillerTotal / 2));
  const older = paddedEntry('f0', fillerTotal - Math.floor(fillerTotal / 2));
  const entries = [call, result, older, newer];
  ctx.setEntries(entries);
  const annotated = annotateToolViews(entries);
  assert.equal(annotated.length, 6);
  const socket = harness.sockets[0]!;
  socket.open();
  socket.message({ protocolVersion: PROTOCOL_VERSION, type: 'history-request', sessionId: 'sess-1' });
  const baseline = lastHistory(socket);
  const cursor = baseline.olderCursor;
  assert.equal(typeof cursor, 'string', 'the baseline must offer an older cursor; the fixture is mistuned');
  const offset = Number((cursor as string).split(':')[0]);
  assert.equal(offset, 3, 'the baseline boundary must be the tool-result index');
  assert.equal(
    (annotated[offset] as { kind?: string }).kind,
    'tool',
    'the anchor must point at a synthetic tool payload',
  );
  socket.message({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: 'sess-1',
    cursor,
  });
  const page = lastHistory(socket);
  assert.equal(page.cursor, cursor);
  assert.equal(page.older, true, 'a valid anchor over synthetic payloads must be honoured');
  assert.deepEqual(page.entries, annotated.slice(0, offset), 'the page must be the strictly older window');
  assert.equal('olderCursor' in page, false, 'the beginning is reached in one more page');
});

// ---------------------------------------------------------------------------
// History annotation
// ---------------------------------------------------------------------------

test('annotateToolViews injects a running frame after each call and a done frame after each result', () => {
  const assistant = {
    type: 'message',
    message: {
      role: 'assistant',
      content: [{ type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'a.ts' } }],
    },
  };
  const result = {
    type: 'message',
    message: {
      role: 'toolResult',
      toolCallId: 'call-1',
      toolName: 'read',
      content: [{ type: 'text', text: 'file body' }],
      isError: false,
    },
  };
  const note = { type: 'note', id: 'n1' };
  const annotated = annotateToolViews([assistant, result, note]);
  assert.equal(annotated.length, 5);
  assert.equal(annotated[0], assistant);
  assert.deepEqual(annotated[1], {
    kind: 'tool',
    toolCallId: 'call-1',
    name: 'read',
    status: 'running',
    view: { type: 'generic', target: 'a.ts' },
  });
  assert.equal(annotated[2], result);
  // Args come only from the earlier assistant message; the result carries none.
  assert.deepEqual(annotated[3], {
    kind: 'tool',
    toolCallId: 'call-1',
    name: 'read',
    status: 'done',
    view: { type: 'file', path: 'a.ts', content: 'file body' },
  });
  assert.equal(annotated[4], note);
});

test('annotateToolViews bounds each inserted payload', () => {
  const hugeContent = Array.from(
    { length: 5000 },
    (_value, index) => `line ${index} ${'y'.repeat(40)}`,
  ).join('\n');
  const assistant = {
    type: 'message',
    message: {
      role: 'assistant',
      content: [
        { type: 'toolCall', id: 'c1', name: 'write', arguments: { path: 'big.txt', content: hugeContent } },
      ],
    },
  };
  const annotated = annotateToolViews([assistant]);
  const tool = annotated[1] as ToolPayload;
  assert.equal(tool.kind, 'tool');
  assert.ok(Buffer.byteLength(JSON.stringify(tool)) <= TOOL_VIEW_MAX_BYTES);
  assert.equal(tool.view!.truncated, true);
});
