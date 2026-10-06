// app-started and project sessions, trust, and spawner wiring.
// Split from the hub test file; test blocks are byte-exact (see .pi/plans/pc-test-split).
//
// Preserved from the original hub test file:
//
// ---------------------------------------------------------------------------
// App-started sessions: start/kill and origin derivation
// ---------------------------------------------------------------------------
//
// ---------------------------------------------------------------------------
// Folder browsing and project sessions
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { afterEach, test } from 'node:test';
import { CLOSE_CAPABILITY, CLOSE_INTERNAL, CLOSE_PROTOCOL, createHub } from '../../src/hub/hub.ts';
import { canonicalizePath } from '../../src/hub/folders.ts';
import { createTicketStore } from '../../src/hub/pairing.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

import { TOKEN, scratchHome, cleanup, startHub, makeFakeSpawner, barrier, closed, connect, helloTokened, helloViewer, sessionEntry } from '../support/hub-harness.ts';

afterEach(cleanup);

test('a viewer start-session invokes the spawner and acks ok', async () => {
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });

  const result = await viewer.next(2000);
  assert.equal(result.type, 'command-result');
  assert.equal(result.id, 'start-1');
  assert.equal(result.ok, true);
  assert.equal(
    Object.prototype.hasOwnProperty.call(result, 'error'),
    false,
    'an ok result must carry no error field',
  );
  assert.equal(spawner.spawnCalls, 1);
});

test('a start-session with no spawner configured is refused', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });

  const result = await viewer.next(2000);
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
  assert.match(String(result.error), /not available/i);
});

test('a spawn rejection returns its message', async () => {
  const spawner = makeFakeSpawner();
  spawner.spawnImpl = async () => {
    throw new Error('boom');
  };
  const hub = await startHub({ spawner });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });

  const result = await viewer.next(2000);
  assert.equal(result.ok, false);
  assert.equal(result.error, 'boom');
});

test('an escaped handler error is contained to its connection', async () => {
  const errors: unknown[] = [];
  const spawner = makeFakeSpawner();
  // SYNTHETIC CONTRACT VIOLATION: production `spawn` always rejects
  // (spawner.ts:155-186); this override manufactures the one shape the entry
  // point has no catch for. It witnesses the guard, not a reachable path.
  spawner.spawn = () => {
    throw new Error('spawn exploded');
  };
  const hub = await startHub({ spawner, onHandlerError: (e) => errors.push(e) });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'boom' });

  const { code } = await closed(viewer);
  assert.equal(code, CLOSE_INTERNAL);
  assert.equal(errors.length, 1);
  assert.match((errors[0] as Error).message, /spawn exploded/);

  // The hub is still serving: a second viewer authenticates.
  const other = await connect(hub.viewerPort);
  await helloViewer(other);
});

test('a throwing onHandlerError sink cannot re-introduce the crash', async () => {
  const spawner = makeFakeSpawner();
  // Same synthetic contract violation as the containment test above, but the
  // observability sink itself throws. The inner guard exists so a broken sink
  // cannot abort the listener; without it this test aborts.
  spawner.spawn = () => {
    throw new Error('spawn exploded');
  };
  const hub = await startHub({
    spawner,
    onHandlerError: () => {
      throw new Error('sink exploded');
    },
  });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'boom' });

  const { code } = await closed(viewer);
  assert.equal(code, CLOSE_INTERNAL);
});

test('a spawn rejection that is not an Error still maps to a string', async () => {
  const spawner = makeFakeSpawner();
  spawner.spawnImpl = () => Promise.reject('boom');
  const hub = await startHub({ spawner });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });

  const result = await viewer.next(2000);
  assert.equal(result.ok, false);
  assert.equal(
    result.error,
    'boom',
    'a non-Error rejection must still serialize a verbatim string, not drop the field',
  );
});

test("exceeding the cap surfaces 'too many app sessions' verbatim", async () => {
  const spawner = makeFakeSpawner();
  spawner.spawnImpl = async () => {
    throw new Error('too many app sessions');
  };
  const hub = await startHub({ spawner });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });

  const result = await viewer.next(2000);
  assert.equal(result.ok, false);
  assert.equal(result.error, 'too many app sessions');
});

test('the sessions payload carries origin derived from the spawner', async () => {
  const spawner = makeFakeSpawner();
  spawner.owned.add(4242);
  const hub = await startHub({ spawner });
  const appAgent = await connect(hub.agentPort);
  const pcAgent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(appAgent);
  await helloTokened(pcAgent);

  appAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    pid: 4242,
    name: 'app one',
  });
  const first = await viewer.nextSessions(2000);
  assert.equal(sessionEntry(first, 's1').origin, 'app');
  assert.deepEqual(spawner.confirmed, [4242], 'the register must confirm the pid');

  pcAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's2',
    pid: 777,
    name: 'pc one',
  });
  const second = await viewer.nextSessions(2000);
  assert.equal(sessionEntry(second, 's2').origin, 'pc');
});

test('a re-register whose origin changes broadcasts the list', async () => {
  const spawner = makeFakeSpawner();
  spawner.owned.add(4242);
  const hub = await startHub({ spawner });
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agent);

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    pid: 4242,
    name: 'same',
  });
  assert.equal(sessionEntry(await viewer.nextSessions(2000), 's1').origin, 'app');

  // The orphan case: the child is no longer owned (e.g. a restarted hub), so
  // the same pid now derives `pc`.
  spawner.owned.delete(4242);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    pid: 4242,
    name: 'same',
  });
  assert.equal(sessionEntry(await viewer.nextSessions(2000), 's1').origin, 'pc');
});

test('kill-session kills an app session', async () => {
  const spawner = makeFakeSpawner();
  spawner.owned.add(4242);
  const hub = await startHub({ spawner });
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agent);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    pid: 4242,
  });
  await barrier(agent);
  await viewer.nextSessions(2000);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'k1',
    sessionId: 's1',
  });

  const result = await viewer.next(2000);
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, true);
  assert.deepEqual(spawner.killed, [4242]);
});

test('kill-session refuses a pc session', async () => {
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner });
  const agent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(agent);
  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    pid: 777,
  });
  await barrier(agent);
  await viewer.nextSessions(2000);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'k1',
    sessionId: 's1',
  });

  const result = await viewer.next(2000);
  assert.equal(result.ok, false);
  assert.equal(result.error, 'not an app session');
  assert.equal(spawner.killCalls, 0);
});

test('kill-session on an unknown session is refused', async () => {
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'k1',
    sessionId: 'ghost',
  });

  const result = await viewer.next(2000);
  assert.equal(result.ok, false);
  assert.equal(result.error, 'unknown session');
});

test('kill-session with a missing sessionId closes as a protocol violation', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'kill-session', id: 'k1' });

  assert.equal((await closed(viewer)).code, CLOSE_PROTOCOL);
});

test('kill-session with an empty sessionId closes as a protocol violation', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'k1',
    sessionId: '',
  });

  assert.equal((await closed(viewer)).code, CLOSE_PROTOCOL);
});

test('kill-session with a missing id closes as a protocol violation', async () => {
  const hub = await startHub();
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'kill-session', sessionId: 's1' });

  assert.equal((await closed(viewer)).code, CLOSE_PROTOCOL);
});

test('an agent listener cannot send start-session', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  await helloTokened(agent);

  agent.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'x' });

  assert.equal((await closed(agent)).code, CLOSE_CAPABILITY);
});

test('an agent listener cannot send kill-session', async () => {
  const hub = await startHub();
  const agent = await connect(hub.agentPort);
  await helloTokened(agent);

  agent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'x',
    sessionId: 's1',
  });

  assert.equal((await closed(agent)).code, CLOSE_CAPABILITY);
});

test('closing the hub awaits the spawner', async () => {
  const spawner = makeFakeSpawner();
  spawner.closeDelayMs = 20;
  const hub = await createHub({
    token: TOKEN,
    tickets: createTicketStore(),
    viewerPort: 0,
    viewerHost: '127.0.0.1',
    spawner,
  });

  await hub.close();

  assert.equal(spawner.closeCalls, 1);
  assert.equal(
    spawner.closeFinished,
    true,
    'hub.close must await spawner.close, not fire and forget',
  );
});

test('two viewers issuing the same start id each get their own result', async () => {
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner });
  const first = await connect(hub.viewerPort);
  const second = await connect(hub.viewerPort);
  await helloViewer(first);
  await helloViewer(second);

  const start = { protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'x' };
  first.send(start);
  second.send(start);

  const firstResult = await first.next(2000);
  const secondResult = await second.next(2000);
  assert.equal(firstResult.id, 'x');
  assert.equal(firstResult.ok, true);
  assert.equal(secondResult.id, 'x');
  assert.equal(secondResult.ok, true);
  assert.equal(spawner.spawnCalls, 2, 'each viewer gets its own spawn attempt');
});

test('a fresh app session is labelled New session', async () => {
  const spawner = makeFakeSpawner();
  spawner.owned.add(4242);
  const hub = await startHub({ spawner });
  const appAgent = await connect(hub.agentPort);
  const pcAgent = await connect(hub.agentPort);
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);
  await helloTokened(appAgent);
  await helloTokened(pcAgent);

  appAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    pid: 4242,
    cwd: '/tmp/pi-droid-session-x',
    sessionFile: '/tmp/pi-droid-session-x/s.jsonl',
  });
  assert.equal(sessionEntry(await viewer.nextSessions(2000), 's1').label, 'New session');

  pcAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's2',
    pid: 777,
    cwd: '/tmp/pi-droid-session-x',
    sessionFile: '/tmp/pi-droid-session-x/s.jsonl',
  });
  assert.equal(sessionEntry(await viewer.nextSessions(2000), 's2').label, 's.jsonl');

  // An app session that later gets an explicit name shows it.
  appAgent.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'register',
    sessionId: 's1',
    pid: 4242,
    name: 'renamed',
    cwd: '/tmp/pi-droid-session-x',
    sessionFile: '/tmp/pi-droid-session-x/s.jsonl',
  });
  assert.equal(sessionEntry(await viewer.nextSessions(2000), 's1').label, 'renamed');
});

test('start-session with a cwd spawns in the canonical directory and persists the trust decision', async () => {
  const home = scratchHome();
  const project = join(home, 'project');
  mkdirSync(project);
  // The parent of trust.json does not exist yet: the write must create it.
  const trustPath = join(home, 'agent-dir', 'trust.json');
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner, homeDir: home, trustPath });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 'start-1',
    cwd: project,
    trust: true,
  });

  const result = await viewer.next(2000);
  assert.equal(result.type, 'command-result');
  assert.equal(result.id, 'start-1');
  assert.equal(result.ok, true);
  assert.deepEqual(spawner.spawnArgs, [{ cwd: canonicalizePath(project), trust: true }]);

  const saved = JSON.parse(readFileSync(trustPath, 'utf-8')) as Record<string, boolean>;
  assert.equal(saved[canonicalizePath(project)], true);
  assert.ok(readFileSync(trustPath, 'utf-8').endsWith('\n'), 'pi writes a trailing newline');
});

test('start-session refuses an invalid cwd without spawning', async () => {
  const home = scratchHome();
  const outside = scratchHome();
  const project = join(home, 'project');
  mkdirSync(project);
  const file = join(home, 'notes.txt');
  writeFileSync(file, 'x');
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner, homeDir: home, trustPath: join(home, 'trust.json') });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  const attempts: Array<[string, unknown]> = [
    ['s1', outside],
    ['s2', 'relative'],
    ['s3', ''],
    ['s4', file],
    ['s5', join(home, 'nonexistent')],
    ['s6', 7],
  ];
  for (const [id, cwd] of attempts) {
    viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id, cwd });
    const result = await viewer.next(2000);
    assert.equal(result.type, 'command-result');
    assert.equal(result.id, id);
    assert.equal(result.ok, false);
  }

  // A non-boolean trust is refused outright, before any spawn.
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 's7',
    cwd: project,
    trust: 'yes',
  });
  const badTrust = await viewer.next(2000);
  assert.equal(badTrust.type, 'command-result');
  assert.equal(badTrust.id, 's7');
  assert.equal(badTrust.ok, false);

  assert.equal(spawner.spawnCalls, 0, 'a refused request must never spawn');
  assert.deepEqual(spawner.spawnArgs, []);

  // A valid cwd still works after the failures.
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 's8',
    cwd: project,
  });
  assert.equal((await viewer.next(2000)).ok, true);
  assert.equal(spawner.spawnCalls, 1);
});

test('start-session re-checks a directory that vanished before the spawn', async () => {
  const home = scratchHome();
  const project = join(home, 'project');
  mkdirSync(project);
  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner, homeDir: home, trustPath: join(home, 'trust.json') });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  // Resolve a real dir, then remove it before the request: the hub must
  // re-resolve immediately before spawning, not trust the listing's path.
  rmSync(project, { recursive: true, force: true });

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 's1',
    cwd: project,
  });

  assert.equal((await viewer.next(2000)).ok, false);
  assert.equal(spawner.spawnCalls, 0);
});

test('start-session passes a saved ancestor decision without rewriting the store', async () => {
  const home = scratchHome();
  const project = join(home, 'project');
  mkdirSync(join(project, '.pi'), { recursive: true });
  writeFileSync(join(project, '.pi', 'settings.json'), '{}');
  const trustPath = join(home, 'agent', 'trust.json');
  mkdirSync(dirname(trustPath), { recursive: true });
  const existing = `${JSON.stringify({ [canonicalizePath(home)]: true }, null, 2)}\n`;
  writeFileSync(trustPath, existing);
  const before = statSync(trustPath).mtimeMs;

  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner, homeDir: home, trustPath });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 's1',
    cwd: project,
  });
  assert.equal((await viewer.next(2000)).ok, true);

  assert.deepEqual(spawner.spawnArgs, [{ cwd: canonicalizePath(project), trust: true }]);
  assert.equal(readFileSync(trustPath, 'utf-8'), existing, 'the store must not be rewritten');
  assert.equal(statSync(trustPath).mtimeMs, before, 'mtime must be unchanged');
});

test('start-session skips a null-valued decision and uses the grandparent', async () => {
  const home = scratchHome();
  const parent = join(home, 'mid');
  const project = join(parent, 'project');
  mkdirSync(join(project, '.pi'), { recursive: true });
  writeFileSync(join(project, '.pi', 'settings.json'), '{}');
  const trustPath = join(home, 'agent', 'trust.json');
  mkdirSync(dirname(trustPath), { recursive: true });
  writeFileSync(
    trustPath,
    `${JSON.stringify(
      { [canonicalizePath(parent)]: null, [canonicalizePath(home)]: true },
      null,
      2,
    )}\n`,
  );

  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner, homeDir: home, trustPath });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 's1',
    cwd: project,
  });
  assert.equal((await viewer.next(2000)).ok, true);

  // `null` is "no decision": the walk continues past it to the grandparent,
  // picking up the grandparent's `true` (a stop-at-null bug would yield false).
  assert.deepEqual(spawner.spawnArgs, [{ cwd: canonicalizePath(project), trust: true }]);
});

test('a malformed trust store fails listing and start loudly and is left byte-identical', async () => {
  const home = scratchHome();
  const project = join(home, 'project');
  mkdirSync(join(project, '.pi'), { recursive: true });
  writeFileSync(join(project, '.pi', 'settings.json'), '{}');
  // A directory with no trust-requiring resources: here the store is read
  // only because the viewer supplied trust explicitly.
  const plain = join(home, 'plain');
  mkdirSync(plain);
  const trustPath = join(home, 'agent', 'trust.json');
  mkdirSync(dirname(trustPath), { recursive: true });
  const malformed = '{ this is not json';
  writeFileSync(trustPath, malformed);

  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner, homeDir: home, trustPath });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'list-dirs',
    id: 'd1',
    path: project,
  });
  const listing = await viewer.next(2000);
  assert.equal(listing.type, 'command-result');
  assert.equal(listing.ok, false);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 's1',
    cwd: project,
  });
  const result = await viewer.next(2000);
  assert.equal(result.type, 'command-result');
  assert.equal(result.ok, false);
  assert.equal(spawner.spawnCalls, 0);

  // Supplying trust explicitly does not skip the store read: pi reads it for
  // the existing decision, so the malformed store must still fail loudly.
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 's2',
    cwd: plain,
    trust: true,
  });
  assert.equal((await viewer.next(2000)).ok, false);
  assert.equal(spawner.spawnCalls, 0);

  // A malformed store is loud, never a silent "no decision", and it must be
  // left exactly as it was found.
  assert.equal(readFileSync(trustPath, 'utf-8'), malformed);

  // The connection is still usable: a later request is answered.
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'list-dirs', id: 'd2' });
  assert.equal((await viewer.next(2000)).type, 'dir-listing');
});

test('a trust.json that is a directory fails loudly without crashing', async () => {
  const home = scratchHome();
  const project = join(home, 'project');
  mkdirSync(join(project, '.pi'), { recursive: true });
  writeFileSync(join(project, '.pi', 'settings.json'), '{}');
  const trustPath = join(home, 'agent', 'trust.json');
  // A directory where the store should be: reading it raises EISDIR, which the
  // trust reader wraps as a loud TrustStoreError.
  mkdirSync(trustPath, { recursive: true });

  const spawner = makeFakeSpawner();
  const hub = await startHub({ spawner, homeDir: home, trustPath });
  const viewer = await connect(hub.viewerPort);
  await helloViewer(viewer);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'list-dirs',
    id: 'd1',
    path: project,
  });
  const listing = await viewer.next(2000);
  assert.equal(listing.type, 'command-result');
  assert.equal(listing.ok, false);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'start-session',
    id: 's1',
    cwd: project,
  });
  assert.equal((await viewer.next(2000)).ok, false);
  assert.equal(spawner.spawnCalls, 0);

  // The hub is still alive and serving.
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'list-dirs', id: 'd2' });
  assert.equal((await viewer.next(2000)).type, 'dir-listing');
});
