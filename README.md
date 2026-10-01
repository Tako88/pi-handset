# pi-droid

An Android chat client for [pi](https://github.com/earendil-works/pi). A supervisor
process and a pi extension run on the PC; a native Android client talks to them over
a WebSocket. The point of the app is streaming text: long assistant replies arrive
token by token and must stay at 60 fps while they render.

Repo-wide rules for contributors and coding agents live in [`AGENTS.md`](AGENTS.md).
This file is orientation, setup and status.

## Status

Both sides are built and tested, and the whole path has been exercised for real:
a real `pi`, a real hub, the **real** Dart client, and the app on an emulator and
then on a phone, driving a live model. All ten attach-protocol milestones are done,
and so is transcript parity with the pi TUI (M1–M3).

| | `pc/` (Node + TypeScript) | `app/` (Flutter + Dart) |
|---|---|---|
| Suite | 354 tests passing | 256 tests passing |
| Static gate | `tsc --noEmit` clean | `flutter analyze` clean |
| Product code | hub, protocol codec, pi bridge | protocol codec, client, UI |

**Transcript parity is done.** The app renders the user's own messages and the
assistant's thinking from one ordered block model fed identically by the live relay
and the snapshot history, shows a live `Working…`/`Thinking…`/`Responding…` status
above the composer, renders tool calls as collapsed blocks that pair each result to
its call, and follows the newest message until you scroll away — where a jump-to-latest
button appears. The app bar carries the session name and how full the model's context
is (`23k / 128k · 18%`, or `? / 128k` while pi cannot say), read at turn boundaries
rather than per token. The status is precise rather than a guess: the bridge relays a
**content-free** `thinking` phase frame first, so a slow first token is never
mislabelled as thinking. The reasoning itself streams too — into its own row above
the reply, replaced by the committed thinking block when the message lands.

One deliberate tradeoff worth knowing: opening a long transcript lays it out once
(O(n)) because starting at the bottom requires it; streaming frames stay lazy. A
thinking-heavy turn roughly doubles the relayed bytes, since the reasoning arrives
once as deltas and again inside the committed message — the committed copy is the
one the transcript keeps, and the live row is retired in the same update that
commits it. The exception: a reasoning-heavy message that exceeds the relay cap
arrives as a byte-count notice instead, so the live row is replaced by that notice
rather than by the thinking block.

**Done:** the wire protocol and codec, single-use pairing tickets, the persisted
pairing token, the discovery file and the lock that makes `serve` exclusive, the
hub (two listeners, listener-bound capabilities, relay, backpressure, and the
session-registry push), the pi bridge extension, shared golden fixtures with a
pure Dart codec, the app — client, pairing, session list and transcript — the
bridge driven inside a real `pi` against a faux provider including its silence as
a process, `serve` minting pairing codes on demand, the real client attaching to
a real hub with a real `pi` behind it, **starting and killing headless app sessions
from the phone** — the hub spawns `pi --mode rpc --no-session` in a fresh empty
temp dir, the spawned pi registers through the same bridge path, the session list
groups app-started sessions above PC ones, and only app rows carry a kill
affordance — and the manual pass: pairing through the UI,
a live model streaming into a rendered transcript, a hub restart survived without
re-pairing — the phone reconnects to the stable viewer port while the bridge finds
the new ephemeral agent port through the discovery file — and the reasoning
streaming live above the reply.

**What is left** is not milestone work — it is an agenda, listed next.

### What is left

An agenda, not a roadmap: nothing here blocks using the app today. Each item says
what it would cost, so it can be picked up cold.

**Bugs, diagnosed and unfixed**

- **Pairing against an unreachable host spins forever.** `HubClient` awaits
  `_socketFactory(url)` with no deadline, and the 10s watchdog is armed only *after*
  the socket exists — so a typo'd or unroutable address hangs until Android's own TCP
  timeout, which is minutes rather than seconds. Fix: race the connect against a ~10s
  deadline, name the host in the error, and close a socket that arrives late. Test
  first: a factory that never completes.
- **The transcript disables Android's predictive-back preview.** The system back button
  is wired with `PopScope(canPop: false)`, which is what stops it exiting the app — but
  the same flag suppresses the peek-at-the-previous-screen gesture preview. The honest
  fix is real routes (a `Navigator` back stack) instead of the state-driven widget swap
  the shell uses; that is a rewrite, which is why it was not done.

**Product gaps**

- **History is a fixed window, not a paged log.** A `snapshot` carries at most
  `HISTORY_MAX_BYTES` (768 KiB) of the *newest* entries; older ones are simply not
  sent, and the app says so above the oldest row it has. A single entry larger than
  the whole window is collapsed to a byte-count notice rather than becoming a wall.
  The real fix is paging — a `fetchOlder` cursor on `history-request` — which is why
  the window is described as a stopgap, not a design.
- **Tool rendering is generic.** Every tool gets the same collapsed block; there are no
  per-tool renderers — no diff, no file, no table.
- **Images are `[image]` placeholders**, and **links are styled but not tappable** (the
  latter needs `url_launcher`, deliberately not taken).
- **No discovery.** The address is typed by hand. Tailscale needs none — its MagicDNS
  name is typed once — but there is no LAN beacon or mDNS path. The emulator can only
  reach the host as `10.0.2.2`, because its NAT hides the LAN entirely.
- **Reinstalling a rebuilt APK *may* drop the pairing**, if the keystore-wrapped
  credential can no longer be decrypted. Observed once, then not reproduced on a
  2026-09-30 reinstall — treat it as unconfirmed rather than a rule. A normal reboot
  does not affect it.

**Known residuals, accepted at the time**

- **Adding an event payload kind needs the hub restarted.** The hub validates an
  inbound payload's kind against the shared list, which it reads at startup, so a
  bridge that emits a newly added kind is closed with 4002 by a hub started before
  that change — and the bridge reconnects rather than giving up, so it loops
  silently. Restart the hub with any change that adds a kind.
- **The context reading can lag during a long tool run.** It is sampled at turn
  boundaries (history replay, settle, compaction, an accepted model switch), not per
  model response, so a multi-step run shows the number from before the run.
- **A usage frame racing a session switch** is attributed to whichever session is
  active when it arrives — the same one-session-model race every relayed event has.
- `lstat` TOCTOU on the token file; a reused PID; `token.tmp.*` left behind by a crash.
- A dropped `sessions` frame is silent — the app shows a stale list rather than saying so.
- The bridge's pi types are a hand-declared structural slice, not pi's real ones.
- `app/test/integration/attach_path_test.dart`'s restart case asserts a stable end
  state, not the restart itself — a non-deterministic regression gate.
- **Live reasoning is best-effort.** A mid-turn `snapshot` (resync, reconnect,
  re-subscribe) drops the live reasoning row, exactly as it already drops the live
  reply row. A provider that emits no `thinking_delta` — only `thinking_end` — shows
  no live row for that block: nothing is lost, because the committed message carries
  it. And redacted reasoning streams as raw deltas before the commit replaces it with
  `[reasoning redacted]`.
- **Streamed reasoning is witnessed by hand, not by the default suite.** `flutter test`
  covers the wire shapes it arrives in, but never a live model emitting them, so the
  only automated end-to-end check is the opt-in, paid `test_live/attach_live_test.dart`
  — which is outside `flutter test`'s glob on purpose. The duplication trap (the live
  row and the committed block both carrying the reasoning) was confirmed absent on the
  phone instead.
- **A changed bridge reaches a running `pi` on reload, whose trigger is not pinned
  down.** The extension loader bypasses the module cache, so the file is re-read on
  every load, and a bridge change was observed going live in a process started before
  it without a restart. Whether that came from a session replacement or something else
  is unverified; a `pi` restart is the sure path, and a stale bridge shows up as the
  phone missing a behaviour the code claims.

**App-started sessions, accepted at the time**

- **A `SIGKILL`ed hub leaks its children.** A graceful `SIGTERM`/`SIGINT` stop runs
  `spawner.close()`, which group-kills every app session. A `SIGKILL` of `serve`
  cannot run any handler: those children survive, reconnect via the rewritten
  discovery file, re-register to the restarted hub as `origin:'pc'` (the new spawner
  does not own their pid), become unkillable from the app, and their temp dirs stay in
  `/tmp`. The upgrade path is a pidfile reaper on boot; not built. `--take-over`
  likewise leaves the old supervisor's children running, because it does not signal
  the old process — pre-existing, out of scope.
- **A spawned child cannot be killed before it registers.** `kill-session` is keyed by
  `sessionId`, which does not exist until the child's `register`; the app has no row
  for it either. The window is bounded by the registration deadline (60 s), after which
  the reaper kills it.
- **The cap is a constant.** 8 simultaneous app sessions, hardcoded, with no CLI flag
  and no UI; the 9th start is refused with `too many app sessions` (surfaced verbatim
  in a SnackBar). Each session is a real pi process, so this is the one unbounded
  resource the feature adds.
- **No spawn-time configuration and no auto-open.** Nothing to pick at spawn (model,
  name, cwd are not offered); the hub cannot know the pi-generated session id at spawn
  time, so a new session appears only when its `register` arrives — a child spawned but
  not yet registered has no row and therefore no kill affordance.
- **`pi` must be on the supervisor's `PATH`.** `spawn('pi', …)` resolves through the
  supervisor process's environment; a systemd/launchd-managed hub may not have it.
- **The bridge must be globally configured.** Production relies on the user's
  `<agent-dir>/settings.json` listing `pc/extensions` (verified on the dev host). If it
  does not, a spawned pi never registers; the registration reaper kills it and the
  start silently yields no row. The hermetic capstone proves the mechanism with an
  equivalent settings file.

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

### What the second pass found, on real hardware

The emulator was never enough, so the app went onto a phone. Three more faults, none
of them reachable from the suite as it stood:

| Fault | Why the suite could not see it |
|---|---|
| The session list never repainted — only the *first* push of a connection notified | the client tests asserted `client.state`, not the `changes` stream, so a state change with no notification passed |
| The system back button exited the app instead of returning to the session list | the tests drive the app through widgets, and no test ever delivered a platform `popRoute` |
| The keyboard covered the composer | no test set a bottom `viewInsets`, so the layout was never exercised with a keyboard present |

The middle one is the sharpest: the app already had a working back affordance in the
AppBar, wired to the same function the system button should have called. Nothing
connected them, and nothing tested the connection. The pattern across both passes is
that tests asserting **internal state** stay green while the **screen** is wrong —
which is the argument for a widget-level assertion that reads geometry and rendered
text, not just the client's fields.

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

**If pairing just spins, suspect the firewall.** With `ufw` on its default `DROP`
input policy, a phone's connection to port 8787 over the LAN is silently dropped.
Tailscale traffic is not dropped, so pairing over the tailnet address needs no rule at
all. Test it **from the phone** — the PC connecting to itself proves nothing:

```sh
adb shell 'timeout 5 toybox nc 192.168.1.100 8787 < /dev/null; echo exit=$?'
# exit=0 -> connected;  exit=124 -> dropped (the firewall)
```

Then, to open the LAN path — scoped to the subnet rather than the world:

```sh
sudo ufw allow from 192.168.1.0/24 to any port 8787 proto tcp
```

### Loading the extension into your own pi

The hub and the app are useless without the **bridge**, and the bridge is a pi
extension: it only exists inside a running `pi`. Register its directory once, in
`~/.pi/agent/settings.json`:

```json
"extensions": [
  "/home/tako/dev/pi/extensions",
  "/home/tako/dev/pi-droid/pc/extensions"
]
```

Every `pi` you start after that attaches to the hub automatically — no flags. Start
them in either order: if pi comes up first the bridge logs `no hub discovered` and
retries on capped backoff until the hub appears.

**Do not copy or symlink the bridge somewhere else.** It imports `../src/hub/auth.ts`,
`../src/hub/discovery.ts` and `../src/protocol/protocol.ts`; a copy resolves those
against the wrong root and fails to load. The path above is the only correct one.

**The `.ignore` file in that directory is load-bearing.** pi loads *every* `.ts`/`.js`
file in a registered directory as an extension — including `*.test.ts` — so
`pc/extensions/.ignore` (containing `*.test.ts`) is what keeps
`pi-droid-bridge.test.ts` from being loaded as a live extension. Files *inside a
subdirectory* are different: only `index.ts` is an entry point there, which is why
the existing `/home/tako/dev/pi/extensions` needs no equivalent.

To confirm the bridge loaded without starting a hub, point the runtime dir at an
empty one and watch for its complaint:

```sh
XDG_RUNTIME_DIR=/tmp/empty PI_DROID_DEBUG=1 pi --mode rpc --no-session -nc
# pi-droid bridge: no hub discovered   <- loaded, and looking for a hub
```

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
