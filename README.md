# pi-droid

An Android chat client for [pi](https://github.com/earendil-works/pi). A supervisor
process and a pi extension run on the PC; a native Android client talks to them over
a WebSocket. The point of the app is streaming text: long assistant replies arrive
token by token and must stay at 60 fps while they render.

Repo-wide rules for contributors and coding agents live in [`AGENTS.md`](AGENTS.md).
This file is orientation, setup and status.

## Status

Both sides are built and tested, and the whole path has been exercised for real:
a real `pi`, a real hub, the **real** Dart client, and the app on an emulator
driving a live model. All ten attach-protocol milestones are done; transcript
parity with the pi TUI is now in progress (M1 of three).

| | `pc/` (Node + TypeScript) | `app/` (Flutter + Dart) |
|---|---|---|
| Suite | 281 tests passing | 148 tests passing |
| Static gate | `tsc --noEmit` clean | `flutter analyze` clean |
| Product code | hub, protocol codec, pi bridge | protocol codec, client, UI |

**Transcript parity, in progress.** The app now renders the user's own messages
and the assistant's thinking from one ordered block model fed identically by the
live relay and the snapshot history, and shows a live `Working…`/`Thinking…`/
`Responding…` status above the composer. That status is precise rather than a
guess: the bridge relays a **content-free** `thinking` phase frame, so a slow
first token is never mislabelled as thinking. Still to come: tool calls and
their results (M2), and stick-to-bottom scrolling (M3).

**Done:** the wire protocol and codec, single-use pairing tickets, the persisted
pairing token, the discovery file and the lock that makes `serve` exclusive, the
hub (two listeners, listener-bound capabilities, relay, backpressure, and the
session-registry push), the pi bridge extension, shared golden fixtures with a
pure Dart codec, the app — client, pairing, session list and transcript — the
bridge driven inside a real `pi` against a faux provider including its silence as
a process, `serve` minting pairing codes on demand, the real client attaching to
a real hub with a real `pi` behind it, and the manual pass: pairing through the UI,
a live model streaming into a rendered transcript, and a hub restart survived
without re-pairing.

**What is left** is not milestone work: links in a rendered reply are styled but
not tappable (that needs `url_launcher`, deliberately not taken), the reinstall of
a rebuilt APK drops the stored pairing because the keystore-wrapped credential can
no longer be decrypted, and `tool` payloads still have no producer — the bridge
ignores tool-call frames by design.

### What the manual pass actually found

Step 18 was split three ways when recon found pairing was unreachable: the
delivery path had been designed, unit-tested and never wired, so a new phone could
not attach at all. That was the pattern for the whole milestone. **Five faults were
found only at the moment a designed path met reality, and four of them were
invisible to a green suite of 118 tests:**

| Fault | Why the suite could not see it |
|---|---|
| The bridge's final message never arrived (`message_end`, not `done`), so every assistant reply streamed in and vanished | the stub supplied the event shape the real host never sends |
| `INTERNET` was declared only in the debug and profile manifests, so a **release** build could not open a socket | manifests are not involved in host-side tests |
| Snapshot entries rendered as nothing — the renderer did not understand pi's raw session shape | client tests see `entries` non-empty; only widgets render |
| Opening a session never requested its history, so past conversation was never shown | `requestHistory` was tested directly; nothing tested that opening triggers it |
| A reconnect discarded the visible transcript | needed a real restart to observe |

One more was introduced by the fix for the reconnect race and caught in review:
re-arming the retry without a cap pinned the client to a session that could never
return. Every one of these lives where design meets reality, which is the argument
for the manual pass, not against it.

## Repo layout

```
pc/         Node + TypeScript — supervisor, pi extension, protocol codec
app/        Flutter + Dart — the Android client
protocol/   shared golden JSON fixtures, asserted by BOTH suites
AGENTS.md   rules and conventions
.pi/plans/  design record — plans, adversarial reviews, execution logs (gitignored, local only)
```

Two first-class halves; neither owns the repo root. **There is deliberately no
manifest at the root**, so every command runs from inside its own side — `npm test`
at the root fails with ENOENT by design, not by accident.

## Running it

```sh
cd pc
npm test                 # whole suite
npm run typecheck        # tsc --noEmit — a separate gate from the tests
```

```sh
cd app
flutter test             # whole suite
flutter analyze          # must be clean

emulator -avd pi-droid &                                   # boot the AVD first
SERIAL=$(adb devices | awk '/device$/{print $1; exit}')    # discover it; don't assume 5554
flutter run --profile -d "$SERIAL"
```

Run both gates on both sides before calling anything done — `npm test` does not run
`typecheck`, and `flutter test` does not run `analyze`.

Both suites now spawn real processes: `pc/`'s suite starts a real `pi` for the
bridge test, and `app/`'s starts a real hub and a real `pi` for the attach test. So
both need `node` and the `pi` CLI on `PATH`. They fail loudly and name the missing
binary rather than skipping, because a test that quietly does not run is not a gate.

The one check that is **not** in a default suite is the live model, because it
spends money:

```sh
cd app
flutter test test_live/attach_live_test.dart       # one short paid call
PI_DROID_LIVE_MODEL=provider/model flutter test test_live/attach_live_test.dart
```

It lives outside `test/` so `flutter test` never picks it up, and it is deliberately
not a `skip:` — a test that is skipped by default is the never-failing gate this
project rejects. Run it by hand when the provider integration matters.

### Pairing a phone

A pairing code is minted **on demand**, not at startup, because it has a 5-minute
TTL: a code printed at launch would usually expire before you reached the phone.

The hub prints how:

```sh
cd pc
node src/cli/serve.ts
# pi-droid serve: ready. Pair a phone: run `kill -USR1 <pid>` to print a pairing code (valid for 5 minutes).

kill -USR1 <pid>     # the pid the line above names
# pi-droid pairing code: ABCD-EFGH (valid for 5 minutes)
```

Enter the PC's address, the viewer port (`--port`, default 8787) and that code in
the app. The phone then stores a token, so pairing happens once per phone and
**restarting the hub does not de-pair**. The code is single-use and dies after 5
failed attempts, so if you mistype it enough times, request a fresh one.

## Local setup

This section describes the machine pi-droid is currently developed on. Paths are
absolute and machine-specific; adjust for a new box.

### Node

Node **22.23.2** (≥22.19 required) and npm **10.9.8**. TypeScript runs through Node's
native type stripping — **no build step, no bundler, no test framework**. Specifiers
are `.ts`. `node --test` runs `.ts` files with no flags; the `--experimental-strip-types`
flag is *not* needed on this version.

Because stripping only erases types, `pc/tsconfig.json` sets **`erasableSyntaxOnly`**.
That flag is load-bearing, not decorative — see Decisions below.

### Flutter

Flutter **3.47.5 stable** (bundles Dart 3.13.4) at `~/develop/flutter`, installed from
the official tarball with its published SHA-256 verified against
`releases_linux.json`. Adding `~/develop/flutter/bin` to `PATH` is the whole install.

Flutter pins the Android targets itself: **compileSdk 36, targetSdk 36, minSdk 24**,
NDK `28.2.13676358` (downloaded on first build).

### Android SDK

SDK root `~/Android/Sdk`, **managed as a single root by Android Studio's SDK Manager**.
Installed: `platform-tools` 37.0.1, `platforms;android-36` (plus `android-37.0`),
`build-tools` 36.0.0, `emulator` 37.1.11, `cmdline-tools` 23.0.0, and
`system-images;android-36;google_apis;x86_64`.

Two deliberate avoidances:

- **Not the AUR `android-sdk*` packages.** They install into `/opt/android-sdk`, a
  *second* SDK root alongside Studio's — two `adb` binaries, two `aapt2`, split
  licences, an `sdkmanager` writing somewhere Studio doesn't read.
- **Not Arch's `android-tools`.** Same reason: it would shadow the Google
  `platform-tools` already present.

Two quirks of `cmdline-tools` 23.0.0 worth knowing:

- **`sdkmanager` is deprecated.** The native `android` binary in the same directory
  replaces it (`android sdk list|install|remove|update`, `android emulator …`).
- **`sdkmanager` and `avdmanager` are Java tools** and fail outright with
  `JAVA_HOME is not set and no 'java' command could be found` without a JDK on the
  path — see below.

### JDK

**No system JDK is installed, and none is needed.** `JAVA_HOME` points at Android
Studio's bundled JBR:

```sh
export JAVA_HOME=/opt/android-studio/jbr   # JDK 25
```

Gradle 9.3.1 (what Flutter 3.47.5 uses) accepts it. The only output is a benign
`WARNING: A restricted method in java.lang.System has been called … Restricted methods
will be blocked in a future release`. Note that JDK 25 is *newer* than what current
AGP officially supports — it works here, but if a future Gradle rejects it, the
fallback is `sudo pacman -S jdk21-openjdk` plus
`flutter config --jdk-dir=/usr/lib/jvm/java-21-openjdk`.

### Emulator

AVD **`pi-droid`**: pixel_7 profile, x86_64, API 36, 4 cores, 4 GB RAM, host GPU.

Two defaults were changed and matter: `flutter create`'s AVD arrived with
`hw.gpu.enabled=no` and 2 GB RAM, i.e. **software rendering**, which makes any frame
timing measurement meaningless. They are now `hw.gpu.mode=host` and 4 GB.

A third change is needed before anyone can **type** into the emulator by hand.
`hw.keyboard=no` means the emulator presents no hardware keyboard to Android, so
all input has to go through the on-screen IME — which is how a manual pass ends up
fighting a soft keyboard wedged over the app. It is now `hw.keyboard=yes`, and with
`show_ime_with_hard_keyboard=0` the soft keyboard stays hidden while the host
keyboard types straight through. Edit `config.ini` with the emulator **stopped**
(it rewrites the file on exit), or use Studio's *AVD Manager → Edit → Show Advanced
Settings → Enable keyboard input*.

Two device settings also bite when driving the emulator from `adb` rather than by
hand, both already set here:

- `settings put secure stylus_handwriting_enabled 0` — otherwise Android's "Try
  out your stylus" panel silently swallows `adb shell input text`, treating the
  keystrokes as handwriting strokes.
- Tap a field's *input area*, not the floating label above it, and never dismiss the
  keyboard with `keyevent 4`: BACK can background the app. When scripting typing,
  remember the string is re-split by the **remote** shell, so spaces must be `%s`
  (`hello%sworld`) or the whole thing quoted for the remote side.

Hardware acceleration works: `/dev/kvm` is present and world-writable, AMD-V (`svm`)
is available, GPU is an AMD RX 9060 XT on RADV/Mesa.

### Shell

Login shell is **fish**; the environment lives in `~/.config/fish/config.fish`:

```fish
set -gx ANDROID_HOME $HOME/Android/Sdk
set -gx ANDROID_SDK_ROOT $HOME/Android/Sdk
set -gx JAVA_HOME /opt/android-studio/jbr
fish_add_path $HOME/develop/flutter/bin
fish_add_path $HOME/Android/Sdk/cmdline-tools/latest/bin
fish_add_path $HOME/Android/Sdk/platform-tools
fish_add_path $HOME/Android/Sdk/emulator
```

## Decisions worth knowing

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
- **Pairing survives a reboot but not a reinstall.** The endpoint and token live in
  keystore-wrapped storage, which a normal restart reads fine but `adb install -r`
  of a rebuilt APK cannot decrypt. So "back to the pairing screen" after a rebuild
  is an install artifact, not a lost pairing — worth knowing before hunting a bug
  that is not there.

## Further reading

- [`AGENTS.md`](AGENTS.md) — the rules: TDD method, toolchain commands, test layout,
  definition of done.
- `.pi/plans/` — the full design record: the stack plan, the app scaffolding plan
  and its adversarial review, and appended execution logs with the red/green
  witnesses. **This directory is gitignored**, so it is a local-only archive; the
  conclusions that matter are summarised above.
