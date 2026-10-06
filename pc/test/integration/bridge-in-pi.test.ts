// a real pi: commands, models and sessions.
// Split from the bipi test file; test blocks are byte-exact.
//
// Preserved from the original bipi test file:
//
/**
 * M9 — the bridge inside a *real* pi, and silence as a real process.
 *
 * Two behaviours, both against a spawned `pi` binary (version 0.87.1):
 *
 * 1. A real pi is started in `--mode rpc` with the bridge and a faux-provider
 *    harness extension loaded (`-ne` disables discovery, explicit `-e` still
 *    loads). The hub receives the bridge's `register`, a prompt driven *through
 *    the hub* produces the faux provider's stream and a terminal `agent_settled`
 *    state, and the viewer gets its `command-result`.
 *
 * 2. In `--mode rpc`, stdout is pi's JSONL protocol channel. The bridge must
 *    never write there — under any outcome (no hub, hub refuses the token). The
 *    bridge's own writes are asserted on stderr, never byte-equality across pi
 *    runs.
 *
 * pi is deliberately driven through the hub rather than pi's stdin: it also
 * exercises the allowlist dispatch path against a live pi.
 *
 * `--print` is only evidence of the mode guard (the bridge is inert there),
 * never of silence while active. It is labelled as such.
 */
//
// ---------------------------------------------------------------------------
// Slash commands
// ---------------------------------------------------------------------------
//
// ---------------------------------------------------------------------------
// Model list and switch
// ---------------------------------------------------------------------------
//
// ---------------------------------------------------------------------------
// Step 3-4 — session replacement and in-place tree navigation, real pi
// ---------------------------------------------------------------------------
//
// ---------------------------------------------------------------------------
// Step 22 — the capstone: bare production args, configured-extension discovery
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, test } from 'node:test';
import { WebSocket } from 'ws';
import { loadOrCreateToken } from '../../src/hub/auth.ts';
import { createSpawner } from '../../src/hub/spawner.ts';
import type { Spawner } from '../../src/hub/spawner.ts';
import { PROTOCOL_VERSION } from '../../src/protocol/protocol.ts';

import { harnessPath, FAUX_TEXT, TEMPLATE_MARKER, TEMPLATE_DESCRIPTION_SENTINEL, BUILTIN_COMMAND_NAMES, BOOT_TIMEOUT_MS, STREAM_TIMEOUT_MS, tmpRoot, runtimeDir, configDir, setupBridgeInPi, cleanupBridgeInPi, waitFor, alive, startHub, publishDiscovery, type Viewer, connectViewer, waitForAppSession, waitForMessage, waitForReplacement, collectPrompt, collectCommandResult, waitForBothFauxModels, collectSwitch, bootPi, drivePrompt, messageText } from '../support/bridge-in-pi-harness.ts';

beforeEach(setupBridgeInPi);
afterEach(cleanupBridgeInPi);

test('a slash command from the phone runs as a command, not as literal text', async () => {
  // `/ping` is loaded by explicit path, so this needs no project trust and does
  // not depend on the user's real agent directory.
  const templatePath = join(tmpRoot, 'ping.md');
  writeFileSync(
    templatePath,
    [
      '---',
      'description: Marker template for the slash-command witness',
      '---',
      TEMPLATE_MARKER,
      '',
    ].join('\n'),
  );

  const collected = await drivePrompt({}, ['--prompt-template', templatePath], '/ping');

  assert.equal(collected.result?.ok, true, 'the prompt was refused');
  const user = collected.messages.find((entry) => entry.role === 'user');
  assert.ok(user, 'no user message was relayed');

  // What lands in the session is the template body, not the typed command. The
  // failure this pins is the literal: `/ping` injected verbatim, leaving the
  // model to interpret a command name as prose.
  const text = messageText(user.payload);
  assert.ok(
    text.includes(TEMPLATE_MARKER),
    `the template was not expanded; the user message was ${JSON.stringify(text)}`,
  );
  assert.ok(!text.includes('/ping'), 'the raw command text was sent verbatim');
});

test("a real pi's command list reaches the viewer", async () => {
  // The description lives in front-matter and is deliberately one distinctive
  // string: the assertion is on the front-matter value, not on pi's body-first-
  // line fallback (truncated to 60 chars).
  const templatePath = join(tmpRoot, 'ping.md');
  writeFileSync(
    templatePath,
    [
      '---',
      `description: '${TEMPLATE_DESCRIPTION_SENTINEL}'`,
      '---',
      TEMPLATE_MARKER,
      '',
    ].join('\n'),
  );

  const { viewer, session } = await bootPi({}, ['--prompt-template', templatePath]);
  const id = 'list-1';
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId: session.sessionId,
    name: 'listCommands',
  });

  const result = await collectCommandResult(viewer, id, STREAM_TIMEOUT_MS);
  assert.equal(result.ok, true, `listCommands was refused: ${String(result.error)}`);
  const commands = result.commands as Array<{ name: string; description?: string }>;
  assert.ok(Array.isArray(commands), 'the result must carry a command list');

  // O3: a CLI template's front-matter description survives as the entry's
  // description. Not an exact list length: discovered skills may add entries.
  const ping = commands.find((command) => command.name === 'ping');
  assert.ok(
    ping,
    `the list must contain the CLI template 'ping', got ${commands
      .map((command) => command.name)
      .join(', ')}`,
  );
  assert.equal(
    ping.description,
    TEMPLATE_DESCRIPTION_SENTINEL,
    'the template front-matter description must travel as the command description',
  );

  // O2: pi's built-ins live in a separate constant that `getCommands` never
  // references, so no built-in may appear in the list.
  const offered = new Set(commands.map((command) => command.name));
  for (const name of BUILTIN_COMMAND_NAMES) {
    assert.ok(!offered.has(name), `built-in ${name} must never be offered`);
  }

  // O3/R2: the bridge registers an internal command to reach a command context.
  // It must not be offered to the app — the bare name would invite a tap that
  // re-enters the same path — and pi's `:N` duplicate form must be hidden too.
  // A hypothetical `pi-droid-session-foo` is a different command and is
  // deliberately still offered, so this pins the exact filter, not a prefix.
  assert.ok(!offered.has('pi-droid-session'), 'the bridge must hide its own command');
  for (const name of offered) {
    assert.ok(
      !name.startsWith('pi-droid-session:'),
      `the bridge's duplicate form ${name} must be hidden`,
    );
  }
});

test('a real pi lists its models and switches between them', async () => {
  const { viewer, session } = await bootPi();

  // Faux availability is async after native registration, so the list is polled
  // rather than asserted once. The bridge's own refusal (below) is the honest
  // red while `listModels` is unallowlisted.
  const models = await waitForBothFauxModels(viewer, session.sessionId, STREAM_TIMEOUT_MS);

  // The credential-leak witness: `headers`, `baseUrl`, `compat` and friends
  // must never travel. Compared as a sorted set — key order is insertion order,
  // not contract.
  for (const entry of models) {
    assert.deepEqual(
      Object.keys(entry).sort(),
      ['id', 'name', 'provider'],
      `a model entry must carry exactly provider, id and name, got ${JSON.stringify(entry)}`,
    );
  }

  const id = 'set-model-1';
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId: session.sessionId,
    name: 'setModel',
    args: { provider: 'faux', id: 'faux-2' },
  });

  const { result, usage } = await collectSwitch(viewer, id, 'faux-2', STREAM_TIMEOUT_MS);
  assert.equal(result.ok, true, `setModel was refused: ${String(result.error)}`);
  const model = usage.model as Record<string, unknown>;
  assert.equal(model.provider, 'faux', 'the usage frame must name the new model');
  assert.equal(model.id, 'faux-2', 'the usage frame must name the new model');
});

test('sessionNew replaces the session and the successor names the old one', async () => {
  const { viewer, session } = await bootPi();
  const old = session.sessionId;

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'new-1',
    sessionId: old,
    name: 'sessionNew',
  });

  const ack = await collectCommandResult(viewer, 'new-1', STREAM_TIMEOUT_MS);
  assert.equal(ack.ok, true, `sessionNew was refused: ${String(ack.error)}`);

  // The replacement itself is the witness. pi tears the old runtime down and
  // starts a new session under a new id; the unbound command-ctx fallback would
  // answer `{cancelled:false}` and leave the id untouched, so the old session
  // would never go away and this wait would time out. Both signals are recorded
  // as they arrive because the hub does not guarantee their order.
  const successor = await waitForReplacement(viewer, old, STREAM_TIMEOUT_MS);
  assert.notEqual(successor.sessionId, old, 'a replacement must change the session id');

  // The successor is a real, live session: the hub replays its history to a
  // subscriber as a `snapshot` frame, like any other session.
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'subscribe',
    sessionId: successor.sessionId,
  });
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: successor.sessionId,
  });
  const history = await waitForMessage(
    viewer,
    (message) => message.type === 'snapshot' && message.sessionId === successor.sessionId,
    STREAM_TIMEOUT_MS,
  );
  assert.ok(Array.isArray(history.entries), 'the successor must answer a history request');
});

test('waitForReplacement records both signals whichever arrives first', async () => {
  // The inversion the old two-sequential-waits form could not survive: the
  // successor's `sessions` push lands BEFORE `session-gone`. Waiting for
  // `session-gone` first would discard this push and then time out.
  const queued: Array<Record<string, unknown>> = [
    { type: 'sessions', sessions: [{ sessionId: 'sess-2', replacesSessionId: 'sess-1' }] },
    { type: 'session-gone', sessionId: 'sess-1' },
  ];
  const viewer = {
    ws: undefined as unknown as WebSocket,
    send: () => {},
    tryNext: async () => queued.shift(),
  } satisfies Viewer;
  const successor = await waitForReplacement(viewer, 'sess-1', 1000);
  assert.equal(successor.sessionId, 'sess-2');
});

test("sessionTree navigates in place, witnessed by the next turn's parentId", async () => {
  const { viewer, session } = await bootPi();
  const sessionId = session.sessionId;
  const firstText = 'the first question';
  const secondText = 'the second question';

  // A first turn gives the tree a user message to navigate back to.
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'tree-p1',
    sessionId,
    name: 'prompt',
    args: { text: firstText },
  });
  const firstTurn = await collectPrompt(viewer, 'tree-p1', STREAM_TIMEOUT_MS);
  assert.equal(
    firstTurn.result?.ok,
    true,
    `the first prompt was refused: ${String(firstTurn.result?.error)}`,
  );
  assert.ok(firstTurn.settled, 'the first turn never settled');

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'tree-list-1',
    sessionId,
    name: 'listTree',
  });
  const listed = await collectCommandResult(viewer, 'tree-list-1', STREAM_TIMEOUT_MS);
  assert.equal(listed.ok, true, `listTree was refused: ${String(listed.error)}`);
  assert.ok('leafId' in listed, 'the listTree result must carry the current leaf');
  const nodes = listed.tree as Array<Record<string, unknown>>;
  const userNode = nodes.find((node) => node.role === 'user');
  assert.ok(userNode, `the tree must contain a user node, got ${JSON.stringify(nodes)}`);
  const assistantNode = nodes.find((node) => node.role === 'assistant');
  assert.ok(assistantNode, `the tree must contain the first reply, got ${JSON.stringify(nodes)}`);

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'tree-nav-1',
    sessionId,
    name: 'sessionTree',
    args: { entryId: userNode.id },
  });
  // The ack and the leaf event race through the hub (both are relayed frames),
  // so they are read in ONE pass: a sequential wait would discard whichever
  // landed first.
  let navigated: Record<string, unknown> | undefined;
  const leafPayloads: Array<Record<string, unknown>> = [];
  const navDeadline = Date.now() + STREAM_TIMEOUT_MS;
  while (Date.now() < navDeadline && (navigated === undefined || leafPayloads.length === 0)) {
    const message = await viewer.tryNext(
      Math.min(1000, Math.max(1, navDeadline - Date.now())),
    );
    if (message === undefined) continue;
    if (message.type === 'command-result' && message.id === 'tree-nav-1') navigated = message;
    if (
      message.type === 'event' &&
      (message.payload as Record<string, unknown> | undefined)?.kind === 'leaf'
    ) {
      leafPayloads.push(message.payload as Record<string, unknown>);
    }
  }
  assert.ok(navigated, 'sessionTree must be acked');
  assert.equal(navigated.ok, true, `sessionTree was refused: ${String(navigated.error)}`);
  assert.ok(leafPayloads.length > 0, 'a leaf event must follow the navigation');
  const leafPayload = leafPayloads[0]!;
  assert.ok('leafId' in leafPayload, 'the leaf event must carry leafId');
  const leafId = leafPayload.leafId as string | null;

  // In place: the same session id still serves the session, so a second turn
  // travels under it — a replacement would have retired this id instead.
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id: 'tree-p2',
    sessionId,
    name: 'prompt',
    args: { text: secondText },
  });
  const secondTurn = await collectPrompt(viewer, 'tree-p2', STREAM_TIMEOUT_MS);
  assert.equal(
    secondTurn.result?.ok,
    true,
    `the second prompt was refused: ${String(secondTurn.result?.error)}`,
  );
  assert.ok(secondTurn.settled, 'the second turn never settled');

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId,
  });
  const history = await waitForMessage(
    viewer,
    (message) => message.type === 'snapshot' && message.sessionId === sessionId,
    STREAM_TIMEOUT_MS,
  );
  const entries = (history.entries ?? []) as Array<Record<string, unknown>>;
  const userEntry = (text: string) =>
    entries.find(
      (entry) =>
        entry.type === 'message' &&
        (entry.message as Record<string, unknown> | undefined)?.role === 'user' &&
        messageText({ message: entry.message }).includes(text),
    );

  // The replayed history is the ACTIVE BRANCH, not the whole file. Navigating to
  // the first user message moved the leaf to its PARENT — the system message pi
  // writes before the first prompt, so `leafId` is an id, not `null` — and the
  // whole first turn is abandoned.
  assert.equal(
    userEntry(firstText),
    undefined,
    'branch projection must drop the abandoned first turn',
  );
  for (const entry of entries) {
    const text = messageText({ message: entry.message });
    assert.ok(
      !text.includes(firstText),
      `the abandoned branch must not be replayed, found ${JSON.stringify(text)}`,
    );
  }
  const secondEntry = userEntry(secondText);
  assert.ok(secondEntry, 'the replayed history must contain the second user message');
  // The navigation witness: the second turn hangs off the leaf the event
  // announced. Without the move it would hang off the abandoned first reply
  // (the pre-navigation leaf), and `leafId` would be that reply's id.
  assert.equal(
    secondEntry.parentId,
    leafId,
    'the second turn must branch from the leaf the event announced',
  );
  assert.notEqual(
    secondEntry.parentId,
    assistantNode.id,
    'the navigated-away first reply must not be the second turn\'s parent',
  );
});

test('a spawned bare pi registers, prompts and dies on kill-session', async () => {
  // The bridge and the faux harness are loaded through *configured-extension
  // discovery* — the same mechanism production uses — with no `-e`. The faux
  // provider is the declared carve-out; the registration path is production.
  const { token } = loadOrCreateToken(configDir);
  const agentDir = join(tmpRoot, 'agent');
  mkdirSync(agentDir, { recursive: true, mode: 0o700 });
  writeFileSync(
    join(agentDir, 'settings.json'),
    JSON.stringify({
      defaultProvider: 'faux',
      defaultModel: 'faux-1',
      extensions: [
        fileURLToPath(new URL('../../extensions', import.meta.url)),
        harnessPath,
      ],
    }),
  );

  const real = createSpawner({
    env: {
      ...process.env,
      PI_DROID_RUNTIME_DIR: runtimeDir,
      XDG_CONFIG_HOME: configDir,
      PI_CODING_AGENT_DIR: agentDir,
      PI_DROID_FAUX_TEXT: FAUX_TEXT,
    },
  });
  const pids: number[] = [];
  // Wrap the real spawner only to observe the pid it hands back; every
  // behaviour is the production one.
  const spawner: Spawner = {
    spawn: async (options) => {
      const pid = await real.spawn(options);
      pids.push(pid);
      return pid;
    },
    owns: (pid) => real.owns(pid),
    confirm: (pid) => real.confirm(pid),
    kill: (pid) => real.kill(pid),
    onChildExit: (listener) => real.onChildExit(listener),
    close: () => real.close(),
  };

  const hub = await startHub({ token, spawner });
  publishDiscovery(hub);

  const viewer = await connectViewer(hub.viewerPort, token);
  viewer.send({ protocolVersion: PROTOCOL_VERSION, type: 'start-session', id: 'start-1' });

  const session = await waitForAppSession(viewer, BOOT_TIMEOUT_MS);
  assert.ok(session.sessionId.length > 0, 'the spawned pi must register a session id');
  assert.equal(session.origin, 'app', 'the spawner-owned pid must derive origin app');

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'subscribe',
    sessionId: session.sessionId,
  });
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'history-request',
    sessionId: session.sessionId,
  });

  const id = 'prompt-1';
  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'command',
    id,
    sessionId: session.sessionId,
    name: 'prompt',
    args: { text: 'say the word' },
  });

  const collected = await collectPrompt(viewer, id, STREAM_TIMEOUT_MS);
  assert.ok(collected.result, 'no command-result arrived for the prompt');
  assert.equal(
    collected.result.ok,
    true,
    `prompt was refused: ${String(collected.result.error)}`,
  );
  assert.ok(collected.settled, 'the spawned agent never settled');
  assert.equal(
    collected.streams.map((stream) => stream.text).join(''),
    FAUX_TEXT,
    'the spawned pi must stream the faux provider reply',
  );

  viewer.send({
    protocolVersion: PROTOCOL_VERSION,
    type: 'kill-session',
    id: 'kill-1',
    sessionId: session.sessionId,
  });
  const killResult = await waitForMessage(
    viewer,
    (message) => message.type === 'command-result' && message.id === 'kill-1',
    5000,
  );
  assert.equal(killResult.ok, true, `kill was refused: ${String(killResult.error)}`);

  await waitForMessage(
    viewer,
    (message) => message.type === 'session-gone' && message.sessionId === session.sessionId,
    5000,
  );
  assert.equal(pids.length, 1, 'exactly one child was spawned');
  await waitFor(
    () => !alive(pids[0]!),
    'the spawned process group to be gone after the kill',
    5000,
  );
});
