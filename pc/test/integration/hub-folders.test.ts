// folder listing.
// Split from the hub test file; test blocks are byte-exact (see .pi/plans/pc-test-split).
//
// Preserved from the original hub test file:
//
// ---------------------------------------------------------------------------
// Folder browsing and project sessions
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, test } from 'node:test';
import { CLOSE_CAPABILITY } from '../../src/hub/hub.ts';
import { canonicalizePath } from '../../src/hub/folders.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

import { TOKEN, scratchHome, cleanup, startHub, barrier, closed, connect, helloTokened, helloViewer } from '../support/hub-harness.ts';

afterEach(cleanup);

test('list-dirs without a path lists the canonical home root', async () => {
  const home = scratchHome();
  mkdirSync(join(home, 'Beta'));
  mkdirSync(join(home, 'alpha'));
  const hub = await startHub({ homeDir: home, trustPath: join(home, 'agent', 'trust.json') });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'list-dirs', id: 'dirs-1' });

  const reply = await viewer.next(2000);
  assert.equal(reply.type, 'dir-listing');
  assert.equal(reply.id, 'dirs-1');
  assert.equal(reply.root, canonicalizePath(home));
  assert.equal(reply.path, canonicalizePath(home));
  assert.deepEqual(reply.entries, ['alpha', 'Beta']);
  assert.equal(reply.trust, null);
  assert.equal(reply.trustRequired, false);
  assert.equal(reply.truncated, false);
});

test('list-dirs with an in-home path lists that directory', async () => {
  const home = scratchHome();
  mkdirSync(join(home, 'project', 'inner'), { recursive: true });
  mkdirSync(join(home, 'project', 'Another'));
  const hub = await startHub({ homeDir: home, trustPath: join(home, 'agent', 'trust.json') });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'list-dirs',
    id: 'dirs-2',
    path: join(home, 'project'),
  });

  const reply = await viewer.next(2000);
  assert.equal(reply.path, canonicalizePath(join(home, 'project')));
  assert.equal(reply.root, canonicalizePath(home));
  assert.deepEqual(reply.entries, ['Another', 'inner']);
  assert.equal(reply.trust, null);
  assert.equal(reply.trustRequired, false);
});

test('list-dirs rejects an outside, relative or nonexistent path as a command-result failure', async () => {
  const home = scratchHome();
  const outside = scratchHome();
  const hub = await startHub({ homeDir: home, trustPath: join(home, 'agent', 'trust.json') });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  const attempts: Array<[string, unknown]> = [
    ['d1', outside],
    ['d2', 'relative/dir'],
    ['d3', join(home, 'missing')],
    ['d4', ''],
    ['d5', 7],
  ];
  for (const [id, path] of attempts) {
    viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'list-dirs', id, path });
    const reply = await viewer.next(2000);
    assert.equal(reply.type, 'command-result');
    assert.equal(reply.id, id);
    assert.equal(reply.ok, false);
  }

  // A bad path never closes the connection; the browser survives one bad folder.
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'list-dirs', id: 'd6' });
  assert.equal((await viewer.next(2000)).type, 'dir-listing');
});

test('list-dirs reports trustRequired for a folder carrying project resources', async () => {
  const home = scratchHome();
  const project = join(home, 'project');
  mkdirSync(join(project, '.pi'), { recursive: true });
  writeFileSync(join(project, '.pi', 'settings.json'), '{}');
  const hub = await startHub({ homeDir: home, trustPath: join(home, 'agent', 'trust.json') });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'list-dirs',
    id: 'dirs-3',
    path: project,
  });

  const reply = await viewer.next(2000);
  assert.equal(reply.trustRequired, true);
  assert.equal(reply.trust, null, 'no decision is stored yet');
});

test('list-dirs is delivered unbudgeted even when the viewer budget is exhausted', async () => {
  const home = scratchHome();
  mkdirSync(join(home, 'visible'));
  const hub = await startHub({
    homeDir: home,
    trustPath: join(home, 'agent', 'trust.json'),
    maxViewerBytes: 1,
  });
  const viewer = await connect(hub.viewerPort);
  // A 1-byte budget drops the post-auth `sessions` push, so authenticate without
  // waiting for it and prove the requested listing still arrives.
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'hello', token: TOKEN });
  await barrier(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'list-dirs', id: 'dirs-4' });

  const reply = await viewer.next(2000);
  assert.equal(reply.type, 'dir-listing');
  assert.deepEqual(reply.entries, ['visible']);
});

test('list-dirs truncates a directory at the byte cap and stays under the frame cap', async () => {
  const home = scratchHome();
  const big = join(home, 'big');
  mkdirSync(big);
  for (let i = 0; i < 5000; i += 1) {
    mkdirSync(join(big, `entry-${String(i).padStart(4, '0')}-${'x'.repeat(40)}`));
  }
  const maxDirBytes = 4096;
  const hub = await startHub({
    homeDir: home,
    trustPath: join(home, 'agent', 'trust.json'),
    maxDirBytes,
  });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'list-dirs',
    id: 'dirs-5',
    path: big,
  });

  const reply = await viewer.next(2000);
  assert.equal(reply.truncated, true);
  const entries = reply.entries as string[];
  assert.ok(entries.length > 0 && entries.length < 5000);
  const encoded = Buffer.byteLength(JSON.stringify(reply));
  assert.ok(encoded < maxDirBytes + 1024, `frame ${encoded} should stay near the budget`);
  assert.ok(encoded < 1024 * 1024, 'frame must stay under the default maxPayload');
});

test('an agent listener cannot send list-dirs', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  await helloTokened(agent);

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'list-dirs', id: 'd1' });

  assert.equal((await closed(agent)).code, CLOSE_CAPABILITY);
});
