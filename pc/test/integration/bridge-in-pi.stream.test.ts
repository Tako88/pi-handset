// a real pi: register, stream, thinking and tools recipes.
// Split from the bipi test file; test blocks are byte-exact.
//
// Preserved from the original bipi test file:
//
// ---------------------------------------------------------------------------
// Step 16 — a real pi, driven through the hub
// ---------------------------------------------------------------------------

import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, beforeEach, test } from 'node:test';

import { FAUX_TEXT, childCwd, setupBridgeInPi, cleanupBridgeInPi, drivePrompt } from '../support/bridge-in-pi-harness.ts';

beforeEach(setupBridgeInPi);
afterEach(cleanupBridgeInPi);

test('a real pi with the bridge registers and a hub prompt streams from the faux provider', async () => {
  const collected = await drivePrompt();

  // This is what M9 asks the hub to have received: the register (above), the
  // stream sequence, the final assistant message, the terminal agent state, and
  // the command-result.
  //
  // The final assistant message matters: the app commits the streamed text into
  // its transcript only on a `message` payload, and clears the streaming buffer
  // on the non-running agent state. If the message arrives after `settled`, the
  // reply is wiped before it can be committed — so the ordering is asserted, not
  // assumed. Real pi delivers the completion as a `message_end` extension event.
  assert.ok(collected.result, 'no command-result arrived for the prompt');
  assert.equal(collected.result.ok, true, `prompt was refused: ${String(collected.result.error)}`);
  // An idle prompt is never queued, so the raw forwarded frame must carry no
  // queued key at all — not even `false`.
  assert.equal(
    collected.result.queued,
    undefined,
    'an idle prompt reply must not report queued',
  );
  assert.ok(collected.running, 'the agent never reported the running state');
  assert.ok(collected.settled, 'the agent never settled');

  // Context usage rides the history replay, so a phone that attaches before any
  // turn has a number to show, and then refreshes when the turn settles.
  assert.ok(
    collected.attachUsage,
    'a context-usage reading must arrive on attach, before any turn runs',
  );
  assert.ok(collected.settledUsage, 'the reading must refresh after the turn');
  const latest = collected.usages.at(-1)!;
  assert.equal(typeof latest.tokens, 'number', 'a settled turn must report a token count');
  assert.ok((latest.tokens ?? 0) > 0, 'the token count must be positive after a real reply');
  assert.ok(latest.contextWindow > 0, 'the model must report a context window');

  // Per-role counts, not a single total. M2 added a THIRD relayed role,
  // `toolResult`; this recipe runs no tools, so its count must be zero — an
  // accidental relay (or a recipe leak) may not pass silently.
  const byRole = (role: string) =>
    collected.messages.filter((entry) => entry.role === role);
  assert.equal(byRole('user').length, 1, 'exactly one user message must be relayed');
  assert.equal(byRole('assistant').length, 1, 'exactly one assistant message must be relayed');
  assert.equal(byRole('toolResult').length, 0, 'a plain reply runs no tools');
  assert.equal(collected.messages.length, 2, 'no role other than user and assistant may be relayed here');

  const assistant = byRole('assistant')[0]!.payload.message as Record<string, unknown>;
  assert.match(
    JSON.stringify(assistant),
    new RegExp(FAUX_TEXT),
    'the final assistant message must carry the provider text',
  );
  assert.equal(
    collected.assistantBeforeSettled,
    true,
    'the final assistant message must arrive before the terminal settled state',
  );
  // The plain recipe emits no thinking, so it must emit no phase frame: a phase
  // the model never entered would mislabel the status.
  assert.deepEqual(collected.phases, [], 'a plain-text reply must not emit a phase frame');
  assert.equal(
    collected.streams.map((stream) => stream.text).join(''),
    FAUX_TEXT,
    'the streamed text must be exactly what the faux provider was scripted with',
  );
  assert.deepEqual(
    // The whole stream channel must be contiguous, not just its text half:
    // reasoning deltas consume seqs too, so a text-only view of the sequence
    // would show gaps that are not really gaps. Compared in ARRIVAL order —
    // sorting would wave through out-of-order delivery on an ordered channel.
    [...collected.streams, ...collected.phases].map((frame) => frame.seq),
    [...collected.streams, ...collected.phases].map((_frame, index) => index + 1),
    'stream seq must be contiguous and start at 1',
  );
});

test('a thinking recipe streams the reasoning before the assistant message', async () => {
  const collected = await drivePrompt({
    PI_DROID_FAUX_MODE: 'thinking',
    PI_DROID_FAUX_THINKING: 'FAUX_REASONING',
  });

  assert.ok(collected.result, 'no command-result arrived for the prompt');
  assert.equal(collected.result.ok, true, `prompt was refused: ${String(collected.result.error)}`);
  assert.ok(collected.settled, 'the agent never settled');

  assert.ok(collected.phases.length > 0, 'a thinking reply must emit the liveness phase frame');
  for (const phase of collected.phases) {
    assert.equal(phase.payload.phase, 'thinking');
  }
  // The first frame of the phase carries no text: it exists to label
  // "Thinking…" before the first chunk lands. Later frames carry the chunks.
  assert.equal(
    collected.phases[0]!.payload.text,
    undefined,
    'the liveness frame must be content-free',
  );
  assert.equal(
    collected.phaseBeforeAssistant,
    true,
    'the phase frame must precede the assistant message it announces',
  );

  // The reasoning itself now streams, one chunk per frame, tagged with its phase
  // so the app can route it away from the reply. This is what the faux provider
  // is scripted with (`faux-provider.ts` opts into `reasoning: true`).
  const streamedReasoning = collected.phases
    .filter((phase) => typeof phase.payload.text === 'string')
    .map((phase) => phase.payload.text as string)
    .join('');
  assert.equal(
    streamedReasoning,
    'FAUX_REASONING',
    'the reasoning must arrive in full, chunk by chunk, before the commit',
  );

  const assistantMessages = collected.messages.filter((entry) => entry.role === 'assistant');
  assert.equal(assistantMessages.length, 1, 'exactly one assistant message must be relayed');
  assert.equal(
    collected.messages.filter((entry) => entry.role === 'toolResult').length,
    0,
    'the thinking recipe runs no tools',
  );
  // The committed message stays authoritative, and is what the transcript
  // renders the durable thinking block from.
  assert.match(
    JSON.stringify(assistantMessages[0]!.payload.message),
    /FAUX_REASONING/,
    'the committed assistant message must carry the thinking body',
  );
  assert.equal(
    collected.streams.map((stream) => stream.text).join(''),
    FAUX_TEXT,
    'reasoning frames must not pollute the streamed reply text',
  );
});

test('a tools recipe relays a toolResult whose toolCallId matches the call', async () => {
  const toolPath = join(childCwd, 'faux-tool.txt');
  writeFileSync(toolPath, 'FAUX_TOOL_CONTENT\nline two\n', { flag: 'w' });

  const collected = await drivePrompt({
    PI_DROID_FAUX_MODE: 'tools',
    PI_DROID_FAUX_TOOL_PATH: toolPath,
  });

  assert.ok(collected.result, 'no command-result arrived for the prompt');
  assert.equal(collected.result.ok, true, `prompt was refused: ${String(collected.result.error)}`);
  assert.ok(collected.settled, 'the agent never settled');

  // Per-role counts, not a single total. The tools recipe adds a THIRD relayed
  // role: `toolResult`. Count it explicitly, or a dropped result passes as
  // cleanly as a double-emitted one.
  const byRole = (role: string) =>
    collected.messages.filter((entry) => entry.role === role);
  assert.equal(byRole('user').length, 1, 'exactly one user message must be relayed');
  assert.equal(
    byRole('assistant').length,
    2,
    'the tool-call turn and the final reply are two assistant messages',
  );
  assert.equal(
    byRole('toolResult').length,
    1,
    `exactly one toolResult must be relayed, got roles ${collected.messages
      .map((entry) => entry.role)
      .join(',')}`,
  );
  assert.equal(collected.messages.length, 4, 'no role other than user, assistant and toolResult may be relayed');

  // The call is in the first assistant message; the result names the same id
  // and carries the tool's output.
  const callMessage = JSON.stringify(byRole('assistant')[0]!.payload.message);
  assert.match(callMessage, /"type":"toolCall"/);
  assert.match(callMessage, /"id":"call-1"/);
  const result = byRole('toolResult')[0]!.payload.message as Record<string, unknown>;
  assert.equal(result.toolCallId, 'call-1', 'the result must pair with the call by id');
  assert.equal(result.toolName, 'read');
  assert.equal(result.isError, false);
  assert.match(
    JSON.stringify(result.content),
    /FAUX_TOOL_CONTENT/,
    'the result content must carry the tool output',
  );
  assert.match(
    JSON.stringify(byRole('assistant')[1]!.payload.message),
    new RegExp(FAUX_TEXT),
    'the final assistant message must carry the provider text',
  );
});
