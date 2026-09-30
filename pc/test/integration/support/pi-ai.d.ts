/**
 * Ambient slice of `@earendil-works/pi-ai` for the M9 faux-provider harness.
 *
 * pi loads extensions through jiti, which resolves `@earendil-works/pi-ai` from
 * pi's own install tree — verified: an extension that imports it loads and runs
 * a real `pi`. `tsc`, run from `pc/`, resolves neither that path nor a copy in
 * `pc/node_modules`, and the alternative (making `pc/` depend on pi's package)
 * is the dependency this package deliberately does not have.
 *
 * So the slice is declared, exactly as the bridge declares its pi types. It
 * keeps the typecheck gate meaningful — the harness body is still checked — at
 * the cost of a drift window: a change to the real faux API compiles green here
 * and fails loudly at runtime, when the import yields `undefined`.
 *
 * Deliberately minimal: only what a test actually calls. `fauxProvider` returns
 * much more than this (deferred responses, `callCount`, `appendResponses`) and
 * none of it is used, so none of it is declared. `fauxThinking`/`fauxText` build
 * the scripted thinking + text content the M1 phase-frame test needs. Add a
 * member here when a test needs it — an unused declaration is surface that can
 * drift for no gain.
 */
declare module '@earendil-works/pi-ai' {
  export interface FauxProviderHandle {
    provider: unknown;
    setResponses(responses: unknown[]): void;
  }

  export function fauxProvider(
    options?: Record<string, unknown>,
  ): FauxProviderHandle;
  export function fauxAssistantMessage(
    content: string | unknown | unknown[],
    options?: Record<string, unknown>,
  ): unknown;
  export function fauxText(text: string): unknown;
  export function fauxThinking(thinking: string): unknown;
  export function fauxToolCall(
    name: string,
    arguments_: Record<string, unknown>,
    options?: { id?: string },
  ): unknown;
}
