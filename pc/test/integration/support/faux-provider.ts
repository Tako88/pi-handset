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

import { fauxAssistantMessage, fauxProvider, fauxText, fauxThinking } from '@earendil-works/pi-ai';

export default function fauxHarness(pi: { registerProvider(provider: unknown): void }): void {
  const mode = process.env.PI_DROID_FAUX_MODE ?? 'text';
  const text = process.env.PI_DROID_FAUX_TEXT ?? 'FAUX_OK';
  const thinking = process.env.PI_DROID_FAUX_THINKING ?? 'FAUX_THOUGHT';
  // The plain recipe keeps the default non-reasoning faux model untouched. The
  // `thinking` recipe advertises `reasoning`, without which pi never surfaces
  // `thinking_start`/`thinking_delta` for the scripted thinking block.
  const reasoning = mode === 'thinking';
  const faux = fauxProvider(
    reasoning ? { models: [{ id: 'faux-1', name: 'Faux Model', reasoning: true }] } : undefined,
  );
  const reply = reasoning
    ? fauxAssistantMessage([fauxThinking(thinking), fauxText(text)])
    : fauxAssistantMessage(text);
  // Two identical responses: M10b drives two prompts through one pi process
  // (the second after a hub restart). M9 consumes only the first.
  faux.setResponses([reply, reply]);
  pi.registerProvider(faux.provider);
}
