# pi-droid

An Android chat client for [pi](https://github.com/earendil-works/pi). A supervisor
process and a pi extension run on the PC; a native Android client talks to them over
a WebSocket. The point of the app is streaming text: long assistant replies arrive
token by token and must stay at 60 fps while they render.

Repo-wide rules for contributors and coding agents live in [`AGENTS.md`](AGENTS.md).
This file is orientation, setup and status.

## Status

Both sides are built and tested. The bridge has met a real `pi`, and the hub now
hands out pairing codes; **the app has still only ever talked to a fake socket**,
so nothing has run end to end. Step 18 of the plan was split three ways when recon
found that pairing was unreachable — the delivery path was designed, unit-tested and
never wired.

| | `pc/` (Node + TypeScript) | `app/` (Flutter + Dart) |
|---|---|---|
| Suite | 275 tests passing | 108 tests passing |
| Static gate | `tsc --noEmit` clean | `flutter analyze` clean |
| Product code | hub, protocol codec, pi bridge | protocol codec, client, UI |

**Done:** the wire protocol and codec, single-use pairing tickets, the persisted
pairing token, the discovery file and the lock that makes `serve` exclusive, the
hub (two listeners, listener-bound capabilities, relay, backpressure, and the
session-registry push), the pi bridge extension, shared golden fixtures with a
pure Dart codec, the app — client, pairing, session list and transcript — the
bridge driven inside a real `pi` against a faux provider, including its silence as
a process, and `serve` minting pairing codes on demand.

**Next up:**

1. **The real client against a real hub** — a Dart integration test driving the
   actual `HubClient` at a real hub with a real `pi` behind it, pairing included.
2. **The manual pass** — the app on the emulator, and one run against a real model;
   that run is the only thing automation still cannot cover.

The gap that matters: the app has never spoken to a hub with a real `pi` behind
it. Two faults have now been found only at the moment a designed path met reality —
the bridge's final message, which cost every assistant reply, and pairing, which
meant a new phone could not attach at all. Both were invisible to a green suite,
because the tests supplied what production never produced. The app's fake-socket
tests are the remaining surface of that shape.

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

## Further reading

- [`AGENTS.md`](AGENTS.md) — the rules: TDD method, toolchain commands, test layout,
  definition of done.
- `.pi/plans/` — the full design record: the stack plan, the app scaffolding plan
  and its adversarial review, and appended execution logs with the red/green
  witnesses. **This directory is gitignored**, so it is a local-only archive; the
  conclusions that matter are summarised above.
