/**
 * M9 test harness: registers a deterministic faux provider inside a real pi.
 *
 * pi ships no selectable faux provider (`--provider faux` is "Unknown provider"),
 * so it is registered from an extension loaded in the *same* process. pi loads
 * extensions through jiti, which resolves `@earendil-works/pi-ai` from pi's own
 * install tree — so this import needs no dependency in `pc/` and none is added.
 * `tsc` cannot resolve that path; `./pi-ai.d.ts` declares the ambient slice.
 *
 * The scripted reply is `PI_HANDSET_FAUX_TEXT` so the test asserts on a value it
 * chose. No network, no spend.
 */

import { existsSync, writeFileSync } from 'node:fs';

import {
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall,
} from '@earendil-works/pi-ai';

/** How long a gated model call waits for its release file before giving up. */
const GATE_TIMEOUT_MS = 20_000;

async function waitForFile(path: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(
    `the faux gate was never released: ${path} did not appear within ${timeoutMs}ms`,
  );
}

export default function fauxHarness(pi: {
  registerProvider(provider: unknown): void;
  on?(event: string, handler: () => void): unknown;
}): void {
  // A cross-process marker for the terminal turn event. The bridge reports
  // `agent_settled` over its socket; when that socket is dead the event is
  // dropped, so a file written inside pi is the only witness that the turn
  // actually ran. A missing `on` must throw rather than skip: a silent skip
  // turns the failure into a 30 s timeout naming the wrong thing.
  const settledPath = process.env.PI_HANDSET_FAUX_SETTLED;
  if (settledPath !== undefined) {
    if (pi.on === undefined) {
      throw new Error(
        'PI_HANDSET_FAUX_SETTLED is set but the pi extension API exposes no on()',
      );
    }
    pi.on('agent_settled', () => writeFileSync(settledPath, ''));
  }
  const mode = process.env.PI_HANDSET_FAUX_MODE ?? 'text';
  const text = process.env.PI_HANDSET_FAUX_TEXT ?? 'FAUX_OK';
  const thinking = process.env.PI_HANDSET_FAUX_THINKING ?? 'FAUX_THOUGHT';
  // The plain recipe keeps the default non-reasoning faux model untouched. The
  // `thinking` recipe advertises `reasoning`, without which pi never surfaces
  // `thinking_start`/`thinking_delta` for the scripted thinking block.
  const reasoning = mode === 'thinking';
  const faux = fauxProvider(
    reasoning
      ? { models: [{ id: 'faux-1', name: 'Faux Model', reasoning: true }] }
      : {
          models: [
            { id: 'faux-1', name: 'Faux Model' },
            { id: 'faux-2', name: 'Faux Two' },
          ],
        },
  );
  const reply = reasoning
    ? fauxAssistantMessage([fauxThinking(thinking), fauxText(text)])
    : fauxAssistantMessage(text);
  // The `tools` recipe scripts one tool call followed by the plain text reply,
  // so pi executes a real tool and emits a `toolResult` message before it calls
  // the model again. Two distinct responses, not the repeated `reply`.
  const responses =
    mode === 'tools'
      ? [
          fauxAssistantMessage(
            fauxToolCall(
              'read',
              { path: process.env.PI_HANDSET_FAUX_TOOL_PATH ?? 'faux-tool.txt' },
              { id: 'call-1' },
            ),
            { stopReason: 'toolUse' },
          ),
          fauxAssistantMessage(text),
        ]
      : [reply, reply];
  // The gate parks the turn *inside* the model call, before any assistant output
  // is produced. The test severs the socket while the factory is blocked, then
  // releases it; only then does the turn run, against a dead transport.
  const reachedPath = process.env.PI_HANDSET_FAUX_GATE_REACHED;
  const releasePath = process.env.PI_HANDSET_FAUX_GATE_RELEASE;
  // The gate rewrites `responses[0]` with the plain reply, which is only the
  // scripted first response in the text recipe: in `tools` mode `responses[0]`
  // is the tool call, and replacing it would silently drop the tool turn —
  // a confusing assertion far from the cause. Refuse the combination up front.
  if (releasePath !== undefined && mode !== 'text') {
    throw new Error('the faux gate is only scripted for the default text recipe');
  }
  if (releasePath !== undefined) {
    const gatePath = releasePath;
    responses[0] = async () => {
      if (reachedPath !== undefined) writeFileSync(reachedPath, '');
      await waitForFile(gatePath, GATE_TIMEOUT_MS);
      return reply;
    };
  }
  faux.setResponses(responses);
  pi.registerProvider(faux.provider);
}
