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

import { fauxAssistantMessage, fauxProvider } from '@earendil-works/pi-ai';

export default function fauxHarness(pi: { registerProvider(provider: unknown): void }): void {
  const faux = fauxProvider();
  faux.setResponses([fauxAssistantMessage(process.env.PI_DROID_FAUX_TEXT ?? 'FAUX_OK')]);
  pi.registerProvider(faux.provider);
}
