# Status

The engineering record: what is built, what each change costs to deploy, and what
the manual passes caught that the suites could not. The short version is in
[`../README.md`](../README.md); what is *left* is the [issue tracker](https://github.com/Tako88/PI-Droid/issues),
and what is *deliberately absent* is [`known-limits.md`](known-limits.md).


Both sides are built and tested, and the whole path has been exercised for real:
a real `pi`, a real hub, the **real** Dart client, and the app on an emulator and
then on a phone, driving a live model. All ten attach-protocol milestones are done,
and so is transcript parity with the pi TUI (M1–M3).

| | `pc/` (Node + TypeScript) | `app/` (Flutter + Dart) |
|---|---|---|
| Suite | `npm test` | `flutter test` |
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

## What is left

**Actionable work lives in the [issue tracker](https://github.com/Tako88/PI-Droid/issues).**
Bugs and gaps are tracked there so that a commit can close them — `Fixes #12` — which
prose in a README cannot do. Each issue says what is wrong, what it would take, and
where the code is.

**Deliberate limits live in [`docs/known-limits.md`](docs/known-limits.md).** These are
things the app does not do *on purpose*, each with its reason. They are a record of
accepted behaviour rather than a work list, which is why they are not issues: filing
them would make the open-issue count misrepresent the project's state.

## What the manual pass actually found

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

## What the second pass found, on real hardware

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

