# Decisions worth knowing

Why the code looks the way it does. Each choice records the alternative it was
chosen over, so it does not have to be re-litigated.


- **Flutter over React Native**, chosen on hot reload, emulator-free visual tests
  (`matchesGoldenFile` runs on the Dart VM), and no JS bridge for the streaming-text
  workload. Accepted cost: Dart is a second language in a repo whose PC side is
  TypeScript, so the wire protocol is hand-ported on both sides rather than shared.
- **A performance spike was run before committing to Flutter** (500 messages, a
  message growing at 100 tok/s, naive vs optimized rendering). Result: **0 of ~726
  frames over the 16.67 ms budget in either mode, reproduced twice** — so Flutter
  clears the workload comfortably, and the mitigations (coalesce deltas per frame,
  plain text while streaming, `RepaintBoundary`) are adopted as insurance rather
  than as proven necessity. Caveat: the emulator is desktop-class hardware, so the
  result is not a device-representative number.
- **`erasableSyntaxOnly` is load-bearing.** Under strip-only mode, non-erasable
  syntax (`enum`, `namespace`, parameter properties) throws at runtime with
  `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`. Without the flag such code passes `npm test`
  and then explodes on any machine running plain `node`. This was verified by
  injecting an `enum` and watching both the type gate and the runtime reject it.
- **Goldens are not yet in use.** The mechanism works headless, but a golden of a
  placeholder screen protects no behaviour, so adoption waits for real UI. Two
  mechanics already established: golden keys resolve relative to the *test file's*
  directory, and failure artifacts land in a `failures/` directory beside the test
  file (gitignored).
- **No codegen for the protocol.** Hand-port it, and keep one fixture file asserted
  by both suites.
- **Markdown via `flutter_markdown_plus`, and only on completion.** The spike
  measured markdown re-parsing as the one real per-frame cost, so a streaming reply
  renders as plain text and is re-rendered as markdown when it completes. Chosen
  over the original `flutter_markdown`, which Google retired, on maintenance grounds:
  `1.0.12` on a roughly two-month cadence, 160/160 pub points, and dependencies of
  just `markdown`/`meta`/`path`. Links are styled but not tappable — that would need
  `url_launcher`, which was not worth a second dependency.
- **The transcript list is lazy, and that is load-bearing.** A non-lazy list
  re-parses every completed markdown message on every rebuild, which at the 16 ms
  frame interval is the exact cost the spike measured. `RepaintBoundary` isolates
  painting only — not rebuild, layout or markdown parse.
- **pi signals assistant completion with `message_end`, not a `done` frame.** The
  bridge's normalizer has a `done` branch because `done` is in pi-ai's transcribed
  event union, but real pi never forwards it on `message_update`: it emits
  `text_start`/`text_delta`/`text_end` and then a separate `message_end` extension
  event carrying the finalized message. `message_end` fires for every role —
  system, user, assistant, tool result — so the bridge relays only `assistant`.
  Getting this wrong is not a no-op: the app commits streamed text to the
  transcript on the `message` payload and clears the streaming buffer on settle, so
  a missing final message means every reply streams in and then vanishes. A green
  stub-tested suite did not catch it; the first run against a real `pi` did.
- **The phone's session label is the *last* user prompt, not the first.** pi's
  own session selector titles a session `name ?? firstMessage`; the phone has no
  search, so tracking the current topic is more useful. Precedence:
  `pi.getSessionName()`, else the last user message, else the hub's basename of
  the session file.
- **The faux provider is registered by an extension, not by pi.** pi has no
  selectable faux provider — `--provider faux` is unknown out of the box — so the
  M9 test loads a second extension that calls `pi.registerProvider(faux.provider)`.
  An extension can `import` from `@earendil-works/pi-ai` because pi loads extensions
  through jiti and resolves it from pi's own tree, but `tsc` cannot, so the import
  is backed by a deliberately minimal hand-declared ambient slice. That is a real
  drift window: a change to the faux API compiles green and fails at runtime.
- **A reconnect must re-establish the subscription — and the retry must be capped.**
  The hub drops a closed connection from a session's subscriber set, so after a
  redial the client has to re-subscribe and re-request history or it silently stops
  updating while still looking connected. But a `session-gone` reply must not re-arm
  that retry without limit: a switched-away or deleted session is gone for good, and
  an agent switching sessions is routine rather than exceptional, so an uncapped
  re-arm turns every later registry push into two doomed frames forever. Retries are
  capped at three, after which the client drops the session and says so.
- **Android does not block `ws://` from Dart's socket stack.** The cleartext policy
  is enforced in the Java networking stack; `dart:io` opens its own sockets, so the
  app connects fine at targetSdk 36 with no `usesCleartextTraffic` and no network
  security config. Verified on-device, not assumed — which matters, because the
  obvious "fix" would have been to weaken the manifest for a restriction that does
  not apply. The deliberate no-TLS decision holds.
- **A connection error must not outlive the connection; a session notice must not
  be cleared by one.** The app shows one error banner, and a failed dial used to
  leave it up forever — reporting a refused connection during a healthy session. It
  now records which errors are connection-scoped and clears those on a successful
  authentication, while notices a reconnect cannot fix (resync gave up, session
  gone, token not persisted) survive. Collapsing them into one bucket and clearing
  it blindly would trade a visible lie for an invisible one.
- **Pairing survives `adb install -r`.** The endpoint and token live in
  keystore-wrapped storage. Repeated replace-installs of a rebuilt, same-signature APK on
  the test phone (2026-10-04) kept the pairing intact — the app relaunched straight into
  the transcript each time. A *changed signing key*, or an `adb uninstall`, still loses
  it, and the app now says so on the pairing screen (`could not read the saved token: …`)
  and returns to pairing rather than spinning on the splash forever.
- **The palette is pi's own, with measured deviations.** Colours come from pi's built-in
  dark and light themes resolved to hex — the accent, the tool state tints, the markdown
  roles, the thinking-level ramp — so a session reads the same on the phone as on the PC.
  Two kinds of change were needed, both because pi's palette is designed for a terminal:
  **contrast** (pi's light palette is broadly sub-AA, and `toolOutput` fails in both
  themes; those values are moved toward `text` until they clear 4.5:1 as text or 3:1 as a
  rule on the worst surface each is used on, hue untouched) and the **dark page**, which
  is darker than pi's HTML-export guess because pi's dark theme declares no background at
  all. Contrast is pinned as a *property* in `app/test/ui/theme_test.dart`, not as hex.
  Typographically the app has two voices — the platform mono face for anything the
  machine produced or named, the platform sans for prose. Every deviation, and the
  known-unguarded edges, are in [`docs/known-limits.md`](docs/known-limits.md).

