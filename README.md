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
| Suite | 568 tests passing | 688 tests passing |
| Static gate | `tsc --noEmit` clean | `flutter analyze` clean |
| Product code | hub, protocol codec, pi bridge | protocol codec, client, UI |

**Transcript parity is done.** The app renders the user's own messages and the
assistant's thinking from one ordered block model fed identically by the live relay
and the snapshot history, shows a live `Working…`/`Thinking…`/`Responding…` status
above the composer, renders tool calls as blocks that pair each result to
its call, and follows the newest message until you scroll away — where a jump-to-latest
button appears. The app bar carries the session name and how full the model's context
is (`23k / 128k · 18%`, or `? / 128k` while pi cannot say), read at turn boundaries
rather than per token. The status is precise rather than a guess: the bridge relays a
**content-free** `thinking` phase frame first, so a slow first token is never
mislabelled as thinking. The reasoning itself streams too — into its own row above
the reply, replaced by the committed thinking block when the message lands. Image
parts render as images, capped at 1024 px wide with the aspect ratio preserved,
and an image part too large to relay is replaced in place with an `[image]`
placeholder while the message keeps its role and text. The composer can send one
downscaled gallery image with a caption.

One deliberate tradeoff worth knowing: opening a long transcript lays it out once
(O(n)) because starting at the bottom requires it; streaming frames stay lazy. A
thinking-heavy turn roughly doubles the relayed bytes, since the reasoning arrives
once as deltas and again inside the committed message — the committed copy is the
one the transcript keeps, and the live row is retired in the same update that
commits it. The exception: a reasoning-heavy message that exceeds the relay cap
with no image part to trim arrives as a byte-count notice instead, so the live row
is replaced by that notice rather than by the thinking block.

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

**Predictive back.** The transcript is a real route over the session list, and the
manifest opts into Android's predictive back, so a back gesture peeks the list under the
finger and can be cancelled; a completed gesture pops the transcript and unsubscribes, as
before. The preview is Android 14+ (or the developer-option toggle on 13; API < 33 still
pops, just without the peek). Deploying this needs **an APK rebuild only** — nothing on
the PC changes, so no hub restart and no pi `/reload`.

**Browse and start a project session.** The phone can open a folder browser over the
PC's home directory and start an app session whose `pi` child runs *in the chosen
folder* rather than in a fresh temp dir, and because it runs in a real folder its
session is saved under that project — `pi --continue` on the PC picks it up. The hub lists only directories whose
`realpath` stays under `$HOME`, offering a symlink only when its target does too. When
the folder carries trust-requiring project resources — pi's `.pi/*` set in the folder
itself, or an `.agents/skills` in it or an ancestor — and pi has no saved decision,
the app asks Trust / Do not trust and writes the answer into pi's own `trust.json`;
a resource-free folder is started without a prompt. Listings are capped by both entry
count and bytes, and the browser says so when a listing is truncated. The whole flow
is gated on a `capabilities` array the hub sends with the first `sessions` frame: an
older hub that lacks it never receives the new frames, and the FAB keeps its old
direct-start behaviour instead.

**Slash commands.** Typing `/name` in the composer runs the command in the session's own
`pi`, rather than sending the text to the model. pi expands prompt templates
(`/implement-vetted`), extension commands (`/review`) and skills (`/skill:name`) before
the text enters the agent, so the transcript shows the expansion. Which commands exist
is pi's business and per session — the bridge asks pi rather than keeping a list. The
trap is that pi's *built-in* editor commands (`/model`, `/resume`, `/tree`, `/compact`,
…) are not commands over this path: pi excludes them from its command list and lets the
text through to the model, so a typed `/model` asks the model a question. The composer
completes commands: typing `/` shows the session's real commands, filtered as you type,
and tapping one inserts `/name ` rather than sending it. The list rides the existing
`command`/`command-result` pair as a `listCommands` request — deliberately no new frame
type, and therefore no capability gate: an old hub answers `ok:false "unknown
command"`, a stale bridge behind a new hub answers `ok:false "command not allowed"`,
and either way the panel just stays empty, where a new frame type would be closed `4003`
and treated as terminal. The panel floats over the transcript and
is capped to the space actually available, so it takes no `Column` slot and cannot
overflow. Opening the `/` overlay refetches the list, so a PC-side `/reload` or a
newly added extension shows up without reopening the session. The built-ins are still
unreachable — see issue #3.

**Session menu.** The transcript's ⋮ menu is the supported way to start a new session,
**fork** the current one, compact it, rename it, choose its thinking level and switch
its model. The menu shows the active level and the current model, both riding the
existing `usage` event payload — the same
payload that already carries the context reading. The list is pi's **auth-configured**
model set, delivered on the existing `command-result` frame as an optional `models`
field: no new frame type and no capability gate, so an old hub answers `unknown
command` rather than closing the connection — though the picker then needs the hub
restarted (see [known limits](docs/known-limits.md)). Compacting asks for confirmation
first, because it summarizes the session, drops older history and interrupts a running
turn. While one runs the app bar reads `Compacting…` in place of the context reading,
and a failure to compact (including an automatic one) reaches the transcript as an error
notice. A *typed* `/compact` is still not a command over this path — see the built-ins
trap above. The same trap applies to a *typed* `/model`: it asks the model rather than
switching anything, so the menu is the way.

**New and fork.** The same menu can replace the session. **New session** starts a fresh
one; **Fork** branches from an earlier user message, picked from a tree of the session's
own messages (user messages only, because a fork lands *before* the chosen turn). Both
run in the session's own `pi` and are gated on the hub's `session-control` capability,
so the two menu items are hidden without it. **New is not the FAB.** The FAB spawns a
new `pi` process — in a fresh temp dir, or a chosen project folder — and consumes a
session slot; New keeps the same process, folder and model and replaces the session in
place. New asks for confirmation first, because the on-screen transcript is replaced
(the old session file, if any, stays on disk — a quick `--no-session` session leaves
nothing behind). The app follows the replacement rather than the ack: the command
result means only "the bridge handed this to pi", and the new session is confirmed
when it registers, at which point the phone re-subscribes to it and requests its
history (empty for New; the branch prefix for Fork). Deploying this needs **an APK
rebuild AND pi `/reload` AND a hub restart** — the four new command names and the new
capability are read at import. See [known limits](docs/known-limits.md) for the
semantics, the 15 s replacement timeout, and why `/resume` is not offered.

**Tree navigation.** The same menu gains **Tree**, beside Fork and behind the same
`session-control` capability. It opens the session's message tree — user and assistant
messages only; tool results, compaction entries and bookkeeping rows are not navigation
targets — with a check on pi's current point. Tapping the marked point answers locally
with "Already at this point"; tapping any other node moves pi's leaf there, in place, in
the session's own `pi`, writing nothing. Because a navigation only moves a pointer, a
replay of the whole session file never changed — so the transcript now follows the
**branch**: the projection is pi's own `buildContextEntries()`, the path from the root to
the current leaf. The re-baseline is driven by a **`leaf` event** the bridge emits from
pi's `session_tree` event, so a `/tree` run on the PC moves the phone too; the app
deliberately does not request history on the tap's ack (the ack means "accepted", not
"navigated") and waits for the signal. Tapping a user node prefills an empty composer,
and only an empty one, with the node's projected text — flattened, so an image-bearing
message prefills `[image]` markers rather than its parts. Navigating is refused while pi
is working; pi's own `/tree` aborts the running turn first, where the phone declines
instead. Deploying this needs **an APK rebuild, a pi `/reload` and a hub restart** — the
`leaf` event kind is validated by the hub at runtime, so a hub that predates it closes the
bridge's connection on the first move. See [known limits](docs/known-limits.md) for the
summary step that is not built and the tree's other edges.

**Tool rendering.** Tool calls render by kind, not as a generic text blob: the bridge
normalizes each call and result into a typed `tool` payload, and the app paints it by
`view.type` — a diff for `edit`/`write`, a file range for `read`, a command and merged
output for `bash`, grouped matches for `grep`/`find`, and a table for `ls`, with a
structured generic fallback for anything else. At most one row is expanded at a time:
the in-flight call opens itself and collapses when the next call starts or the turn
settles; settled history is always collapsed (a snapshot taken mid-turn still opens the
in-flight row). The view is **optional** — a frame without one (or with a `view.type`
the app does not know) still decodes and renders through the fallback, so an app and
bridge that are out of step never drop a tool block. Tool payloads are bounded to a
quarter of the relay budget; under a severe backlog such a frame can still be dropped
whole, which the hub's resync path recovers from the unbudgeted history snapshot
(collapsed). The deviations this rests on — bash's merged streams, write's addition-only
"diff", `ls` as the only table source, the history byte-doubling — are recorded in
[known limits](docs/known-limits.md).

**What is left** is not milestone work — actionable items are tracked as issues, and
deliberate limits are recorded separately.

### What is left

**Actionable work lives in the [issue tracker](https://github.com/Tako88/PI-Droid/issues).**
Bugs and gaps are tracked there so that a commit can close them — `Fixes #12` — which
prose in a README cannot do. Each issue says what is wrong, what it would take, and
where the code is.

**Deliberate limits live in [`docs/known-limits.md`](docs/known-limits.md).** These are
things the app does not do *on purpose*, each with its reason. They are a record of
accepted behaviour rather than a work list, which is why they are not issues: filing
them would make the open-issue count misrepresent the project's state.

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
node src/cli/main.ts serve
# pi-droid serve: ready. Pair a phone: run `node /abs/path/pc/src/cli/main.ts pair` to print a code and QR (valid for 5 minutes).

node src/cli/main.ts pair
# pi-droid pairing code: ABCD-EFGH (valid for 5 minutes)
# Scan to pair:
# <a QR of pidroid://pair?v=1&code=ABCD2345&port=8787&lan=192.168.1.10>
# Reachable at port 8787:
#   Home network 192.168.1.10:8787
```

`pair` talks to the running hub over a `0600` Unix control socket under the
runtime dir, so it only works on the same machine. The QR encodes a
`pidroid://pair` URI; scanning it with the app fills in the address, port and
code. With `--no-lan` the hub advertises no addresses, so the QR carries the
code only. The legacy `kill -USR1 <pid>` route still prints a code; `pair` is the
supported path and also prints the QR and the reachable addresses.

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
extension: it only exists inside a running `pi`. `pc/` is a pi package, so install it
with pi's own package command:

```sh
pi install /path/to/pi-droid/pc
```

That records the package in `~/.pi/agent/settings.json` and loads the bridge from
where it sits, so a checkout is used in place — nothing to copy, nothing to keep in
sync. Every `pi` you start afterwards attaches to the hub automatically — no flags.
Start them in either order: if pi comes up first the bridge logs `no hub discovered`
and retries on capped backoff until the hub appears.

Install the **directory**, never a copy or a symlink of it. The bridge imports
`../src/hub/auth.ts`, `../src/hub/discovery.ts` and `../src/protocol/protocol.ts`,
which only resolve from inside the real `pc/` tree.

Two things to know about the recorded path:

- `pi install` stores it **relative to the settings file**, so moving the checkout
  breaks the install — re-run `pi install` from the new location. `pi list` prints
  the resolved absolute path, which is the quickest way to check.
- Registering the directory by hand still works. If you already have the old
  `"extensions": ["…/pc/extensions"]` entry, you can drop it; the package and the
  directory entry resolve to the same file.

**The `.ignore` file is load-bearing.** A package's `extensions/` directory is
scanned for `*.ts`/`*.js`, including `*.test.ts`, so `pc/extensions/.ignore`
(containing `*.test.ts`) is what keeps `pi-droid-bridge.test.ts` from being loaded
as a live extension.

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

## Further reading

- [`AGENTS.md`](AGENTS.md) — the rules: TDD method, toolchain commands, test layout,
  definition of done.
- `.pi/plans/` — the full design record: the stack plan, the app scaffolding plan
  and its adversarial review, and appended execution logs with the red/green
  witnesses. **This directory is gitignored**, so it is a local-only archive; the
  conclusions that matter are summarised above.
