/**
 * M9 test harness: registers a deterministic faux provider inside a real pi.
 *
 * pi ships no selectable faux provider (`--provider faux` is "Unknown provider"),
 * so it is registered from an extension loaded in the *same* process. pi loads
 * extensions through jiti, which resolves `@earendil-works/pi-ai` from pi's own
 * install tree — so this import needs no dependency in `pc/` and none is added.
 * `tsc` cannot resolve that path; `./pi-ai.d.ts` declares the ambient slice.
 *
 * The scripted reply is `PI_DROID_FAUX_TEXT` so the test asserts on a value it
 * chose. No network, no spend.
 */

import {
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall,
} from '@earendil-works/pi-ai';

export default function fauxHarness(pi: {
  registerProvider(provider: unknown): void;
}): void {
  const mode = process.env.PI_DROID_FAUX_MODE ?? 'text';
  const text = process.env.PI_DROID_FAUX_TEXT ?? 'FAUX_OK';
  const thinking = process.env.PI_DROID_FAUX_THINKING ?? 'FAUX_THOUGHT';
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
              { path: process.env.PI_DROID_FAUX_TOOL_PATH ?? 'faux-tool.txt' },
              { id: 'call-1' },
            ),
            { stopReason: 'toolUse' },
          ),
          fauxAssistantMessage(text),
        ]
      : [reply, reply];
  faux.setResponses(responses);
  pi.registerProvider(faux.provider);
}
