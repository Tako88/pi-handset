# Known limits

Things pi-droid deliberately does not do, and why. This is a record of **accepted
behaviour, not a work list** — anything actionable lives in the
[issue tracker](https://github.com/Tako88/PI-Droid/issues).

Most entries are consequences of how pi itself behaves, or of a design decision that
traded one problem for a smaller one. Each states the reason so nobody has to
re-derive it — and so a change that removes the constraint can delete the entry
rather than guess at it.

## General

- **A queued (steered) message is still invisible until pi injects it — but the send is
  now acknowledged.** The composer shows a transient **`Queued for the running turn`**
  SnackBar when the bridge reports the send was queued, so the immediate "did it send?"
  doubt is answered; the message itself still does not appear until pi injects it, after
  the current turn *and its tool calls*, so a user who looks only at the transcript
  minutes later still sees no marker and can resend into a duplicate steer. The notice
  reports **the bridge's dispatch decision**, not pi's acceptance: `sendUserMessage` is
  fire-and-forget, so the optional `queued` key on `command-result` is a claim about what
  the bridge chose, not proof pi took it. It can be wrong in four known ways — during
  compaction, when an input handler swallows the prompt, when a registered extension
  command ran immediately, and when pi throws inside its internal steer queueing
  (unverifiable read-only; swallowed by the fire-and-forget send). The first three are
  documented below; the fourth is an accepted unknown. A session-scoped marker would
  need a signal pi does not expose (`queue_update` is RPC/interactive-only; `hasPendingMessages()`
  is a bare boolean) and a clearing rule with no clean trigger, so it is deliberately not
  built.
- **An extension input handler can swallow a prompt while the notice says it was
  queued.** If any extension's `input` handler returns `"handled"`, pi's `prompt()`
  returns early with no queue and no throw, so the message never lands while the bridge
  has already reported `queued:true`. Latent in this deployment — the only configured
  `input` handler (`test-runner`) returns `"continue"` — but live for any deployment that
  returns `"handled"`, and there is no reachable detector.
- **A send during compaction is still silently dropped.** `isIdle()` is false while
  compacting, so the bridge sends `deliverAs:'steer'`, but pi's compaction check runs
  before its streaming check and throws regardless of `streamingBehavior`; the refusal
  only reaches pi's stdout, which the hub drains. `ExtensionContext` has no `isStreaming`
  or `isCompacting`, so the bridge cannot *poll* for compaction at dispatch time (it can
  observe the compaction events — see below). The bridge reports
  `queued:true` and the notice appears anyway. Pre-existing, not made worse. Not built.
- **The app shows compaction progress but does not gate the composer.** The app bar says
  `Compacting…` in place of the context reading while a compaction runs, driven by
  `session_before_compact` — an extension event pi emits before the summarization call
  from both entry points, for `manual`, `threshold` and `overflow` alike. It is cleared by
  `session_compact` (the success path) or `session_compact_failed` (the `catch` of both
  paths). Two residuals: a **hard-killed** pi sends neither, leaving the indicator up until
  the session is reopened; and an app that **reconnects mid-compaction** never sees the
  start event, so it shows nothing for the remainder. The composer is still not disabled —
  a prompt sent during compaction is silently dropped (above).
- **The compact-failure notice covers auto compactions too.** The bridge surfaces every
  `session_compact_failed` reason — `manual`, `overflow` and `threshold` — so an error
  notice in the transcript can describe an automatic compaction the user did not trigger.
  Deliberate: an auto-compaction failure is at least as consequential as a manual one, and
  it is otherwise invisible.
- **The model picker offers only auth-configured models.** The list is pi's available
  set, which omits any provider with no configured auth. Asking the bridge to switch to
  one anyway cannot succeed: pi's own extension `setModel` refuses a provider with no
  configured auth, which the bridge reports as `model not accepted` (an unknown provider
  or id fails earlier as `model not found`). Reason: only listed models can actually be
  selected, so offering the rest would present choices that cannot work.
- **A scoped session still lists every available model.** A session launched with
  `--models` / `enabledModels` gets the whole auth-configured set in the picker, and
  switching to a model outside the scope succeeds silently. pi's available set is
  auth-filtered only and consults no scope, and the bridge asks for the switch without
  `persist` — the only branch that adds a model to the scope — so the switch leaves the
  scope unchanged. This is a deliberate divergence from pi's own selector, which cycles
  the scoped set when one is configured.
- **A model switch is refused while pi is working** (streaming or compacting), with a
  visible error. Reason: pi's own `AgentSession.setModel` has no such guard and would
  mutate the model under the in-flight call and cascade a thinking-level change; the phone
  cannot see streaming state, so a mixed-model turn is not worth the ambiguity. The guard
  is best-effort — it is read at dispatch, and pi re-reads streaming state after its own
  preflight.
- **A PC-side model change is pushed to the app.** The bridge subscribes to pi's
  `model_select` event and re-emits the usage payload — the same mechanism the thinking
  level already uses — so a switch made on the PC updates the phone's model label without
  a prompt.
- **Deploy gate for model switching: the hub restarted and pi `/reload`ed or restarted,
  plus a rebuilt APK.** `listModels` is a new name in the hub's command allowlist, read at
  import, and the bridge that answers it is read from disk per load; the picker itself
  ships in the app. An old hub answers `ok:false "unknown command"` to every `listModels`,
  which the app turns into a SnackBar on each attempt — louder than `listCommands`'
  silently empty panel; a stale bridge answers `ok:false "command not allowed"`. No 4002
  close and no reconnect loop, because no new frame type is involved.
- **Extension commands sent mid-turn execute immediately, so the queued notice is wrong
  for them.** pi runs `_tryExecuteExtensionCommand` *before* its compaction and streaming
  checks, so a registered command like `/review` runs now rather than queuing while the
  bridge reports `queued:true`; a prompt template like `/implement-vetted` expands and
  then steers. This is pi's design, inherited by the `/` slash-completion; the command
  did run, so only the wording is wrong. Documented, not fixed.
- **Deploy gate for the queued signal: APK rebuild + install and pi `/reload`, but no
  hub restart.** `compose_bar.dart`, `hub_client.dart` and `protocol.dart` are compiled
  into the app, so without a rebuilt APK the notice never appears; the bridge is read
  from disk by pi, so a running pi needs `/reload` (or a restart) to send the flag. The
  hub does not decode agent frames and forwards the parsed object verbatim, so no hub
  restart is needed.
- **Correction:** the earlier claim that pi's mid-turn refusal was "surfaced verbatim in
  a snackbar" was wrong. `sendUserMessage` is fire-and-forget, so the refusal never
  reached the app and the message was silently lost; the successful `command-result`
  said `ok:true` regardless. Reading `isIdle()` at dispatch is what fixes the loss.
  Single check at dispatch: a run starting between the check and pi's own re-read still
  drops, as today — never worse, not race-free.
- **A rejected credential still redials in the background until you re-pair.** Bounded
  and payload-free (capped backoff, one connect plus one `hello` per attempt), but it
  does not stop on its own. Stopping it needs a terminal "credential rejected" signal,
  which the hub deliberately does not send — the same path guards ~2^40 pairing tickets
  — and a client-only heuristic risks giving up on a healthy-but-slow hub. Upgrade path
  if ever wanted: a bounded give-up on consecutive auth timeouts that does **not**
  delete the stored token. Not built.
- **A cold start against an unreachable host still shows the root spinner for up to the
  10s deadline**, because `_bootstrap` awaits the first dial before rendering the form.
  Bounded now, but rendering the form before the dial lands is a change not taken.
- **The pairing submit button stays live during an attempt**, so a double-tap restarts
  it. Safe — the displaced attempt is disposed — but it is a restart, not a queue.
- **A background error can wipe a half-typed pairing code.** `PairingScreen` clears the
  code field whenever `lastError` *changes* — harmless while the form was disabled
  during a redial, not harmless now that the fields are live. In practice the
  stale-token loop repeats one identical message, so the change-guard holds; a
  differently-worded error landing mid-typing would clear the field.
- **A displaced pairing attempt's `paired` frame can still win a microtask race.**
  `_onPaired` has no generation guard, and the shell persists `_pendingEndpoints` on
  `connected` only when `_persistOnConnect` is set, so a frame already queued when a new
  submit lands can pair host B's endpoint with host A's token. The normal path closes the socket first, so the window
  is sub-millisecond and the next re-pair fixes it. Accepted: guarding it cannot be
  tested cleanly with the current fakes, and a test that cannot fail is not a test.
- **Deploy gate: adding an event payload kind needs the hub restarted AND pi
  restarted (or `/reload`ed).** The hub validates an inbound payload's kind against
  the shared list, which it reads at startup, so a bridge that emits a newly added
  kind is closed with 4002 by a hub started before that change — and the bridge
  reconnects rather than giving up, so it loops silently. The bridge is also read
  from disk by pi, so a running pi keeps the old one until it is restarted or
  `/reload`ed. Restart both before judging a new kind; a missed step shows only as a
  silent reconnect loop.
- **Notifications stop if the app process is killed or the task is swiped away.**
  `HubConnectionService` is `START_NOT_STICKY` with `stopWithTask="true"`, and it is
  started only while the app is foregrounded (an FGS may not be started from the
  background on API 31+). A swipe-from-recents destroys the Flutter activity, the main
  isolate and its `dart:io` WebSocket, so no settles arrive until the app is reopened
  (which restarts the service). A sticky restart is deliberately not planned: it cannot
  reconstruct the Dart socket and would only leave a zombie persistent notification.
  Backgrounding with Home keeps the activity and the socket alive.
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
- **Delivering `listCommands` needs the hub restarted and pi `/reload`ed or restarted.**
  The hub's allowlist is code read at import, and the bridge is read from disk per
  load. Unlike a new event payload kind, a missed step fails gracefully: an old hub
  answers `ok:false "unknown command"` (a stale bridge, `ok:false "command not
  allowed"`) and the suggestion panel simply stays empty — no 4002 close, no silent
  reconnect loop.
- **A new app against an old hub sends one `listCommands` per session open forever and
  gets `unknown command` back.** Accepted, because capping after repeated refusals would
  permanently suppress the list after a mid-run hub upgrade, and a per-connection
  counter cannot know the hub changed. It produces no error banner, no retry and no
  stuck state.
- **The suggestion panel shrinks with the keyboard at large text scale.** It is capped
  to the space actually available (`min(200, available)`), so with the keyboard up at
  2× text scale it collapses toward the transcript area and scrolls. Below roughly two
  rows it is a scroll window rather than a browseable list; the alternative is an
  overflow or a panel that steals the transcript's space.
- **A protocol mismatch stops the bridge, and the only notice is debug-gated.** The hub
  closes a version mismatch — and any other protocol violation — with `4002`, and the
  bridge now treats that close as terminal rather than reconnecting forever. The single
  line naming the reason (`pi-droid bridge: protocol close 4002; not reconnecting`) is
  written only when `PI_DROID_DEBUG=1`, because the bridge's silence guarantee — it must
  never write to pi's stderr unprompted — is deliberate. Retrying would only reach the
  same rejection, and a mismatched pair is a deploy-time error the operator fixes with
  `pi /reload`, not a transient failure. Upgrade path if a default-visible signal is ever
  wanted: a status frame surfaced in the app, not an unconditional stderr write.

## Hub

- **An unauthenticated viewer is closed after 10 s, and at most 64 unauthenticated
  viewers are accepted** — the viewer listener only, since that is the LAN-exposed
  surface; the agent listener is loopback-only. The deadline is armed on the agent
  listener too, so a loopback dial that never `hello`s is closed at 10 s (the bridge
  hellos immediately on open); a bridge restart storm that stalls dials past 10 s would
  now close agents that previously survived. **A TCP socket that never completes the
  WebSocket handshake is not covered** — `server.on('connection')` fires post-upgrade,
  and HTTP `headersTimeout`/`requestTimeout` are deliberately not set — so this does
  **not** claim to solve fd exhaustion from raw TCP. **Once `hello` succeeds a connection
  has no idle timeout: its fd is held indefinitely regardless of activity**, so fd
  exhaustion by *authenticated* peers is not solved either.
- **A session caps outstanding commands at 128 total queued entries.** The over-cap
  command is refused (`too many outstanding commands`), never queued or forwarded.
  `pendingHistory` is **not** capped here; its distinct-cursor bound is already recorded
  under **History paging** below.
- **A listing scans at most 10 000 raw directory entries and resolves at most that many
  symlinks.** Beyond it the result is the alphabetically-first N of the scanned window,
  not of the whole directory, and `truncated` says so — so a directory large enough to
  hit the scan cap can hide an entry that sorts before one that is shown.

## Images

- **A large image is not rendered; its part is replaced in place and the text
  survives.** An image part whose bytes would push the message past the 256 KiB
  relay cap (`MAX_RELAY_BYTES`) is replaced by `{type:'image',truncated:true,bytes}`,
  and the app draws the `[image]` placeholder in its place; the message keeps its
  role and text, so a short caption no longer vanishes with a big attachment (#32).
  The bytes never reach the phone — the cap forbids it — so the image itself cannot
  be recovered; the text can, which is the point. The trim is bounded
  (`TRIM_MAX_ITERATIONS`) and falls back to the whole-message `{truncated:true,bytes}`
  marker when the message cannot be rescued: the text alone busts the cap, there is
  no trimmable image part, or there are more image parts than the bound. The same
  trim runs on the history-collapse path, so a reconnect keeps the text too.
- **A message trimmed to the relay cap can still make an over-budget frame.**
  `boundMessage` targets the *message*, but the hub's per-viewer budget
  (`sendToViewer`) measures the whole `{protocolVersion,type,payload}` frame against
  the same `MAX_RELAY_BYTES`. A message that fits the cap exactly therefore produces
  a frame that does not, and the hub drops it whole and tells the viewer to resync.
  Pre-existing and unchanged by the image work; the visible effect is churn, not
  loss, because the recovery snapshot is unbudgeted. The better fix is the
  `TOOL_VIEW_MAX_BYTES` precedent — bound the payload below the budget by an envelope
  margin — deliberately not taken here because it would change which text-only
  messages get trimmed.
- **A pathologically tall image is not memory-bounded by the decode cap.** The
  renderer sets only `cacheWidth: 1024` (setting both dimensions would default
  `ResizeImage` to `ResizeImagePolicy.exact` = `BoxFit.fill` and squash every image
  into a square), and `ResizeImage.allowUpscaling` defaults to false. That bounds a
  normal wide photo, but a very narrow image is not width-clamped, so its decode is
  not bounded by the 1024 figure; the `maxHeight: 320` + `BoxFit.contain` still bound
  the row. A real photo is unaffected.
- **An image cannot be sent on its own; it needs a caption.** The bridge refuses a
  `prompt`/`steer`/`followup` with a missing or empty `text` before it looks at
  `images`, so a picked image must travel with some words. Tapping send with a chip
  and an empty draft therefore shows `'Add a caption to send the image'` and sends
  nothing, rather than a dead tap.
- **The `attachments` capability is advertised by the hub while the image mapping
  lives in the bridge, so a hub restart and a pi `/reload` must deploy together.**
  A new hub with an old bridge advertises `attachments`, the app offers the `+`, and
  the old bridge ignores the unknown `images` field and sends text only — a silent
  drop with no signal to close it. The bridge's shape-refusal cannot detect an old
  bridge; deploy discipline (restart the hub *and* reload pi) is the only defence.
  Against an old hub the app shows no `+` at all.
- **One gallery image per send, and no camera capture in the gallery path.** The chip
  holds at most one image and picking again replaces it; a chip list, drag-reorder and
  camera capture are not built. The gallery path deliberately avoids the camera (the
  `CAMERA` permission in the main manifest belongs to QR scanning, not image picking).
- **The 350 KiB local cap is the only guaranteed size defence, and it is coupled to
  the hub's 1 MiB `maxPayload`.** A picked image over `maxAttachmentBytes` (350 KiB) is
  refused locally with `'That image is too large to send'` — never sent as a frame the
  hub would drop. Base64 inflates by 4/3 (350 KiB → ~467 KiB), which fits the whole
  `{protocolVersion,type,payload}` envelope inside the default `maxPayload` of 1 MiB;
  pi 1.0.0 normalizes prompt images but 0.84.1 does not, so nothing downstream can be
  relied on. The cap assumes that 1 MiB default (configurable in `HubOptions`, but
  `serve` exposes no CLI flag for it); a hub run with a smaller payload would turn an
  at-cap frame into the silent drop the guard exists to prevent. There is no
  shrink-and-retry: an over-cap image must be replaced with a smaller one.

## Tool rendering

- **bash stdout and stderr arrive merged, and there is no structured exit code.** pi
  points both streams at one `onData` sink and carries no code in the result's
  `content` or `details`; a non-zero exit is thrown as an error instead. So the command
  view shows the command plus one merged output pane, and derives `exitCode` by
  parsing a trailing `Command exited with code N` for failures, and by recording `0`
  when `isError` is false. `Command aborted`, `Command timed out after N seconds` and
  `Command terminated without an exit code` parse to *no* code, even though their text
  contains digits. Separating the streams is impossible from the relayed data.
- **write has no old-content diff, and its summary claims no line delta.** pi's `write`
  returns `details: undefined` and `Successfully wrote to <path>`; the file's previous
  contents are nowhere on the extension surface. The write view is therefore a diff
  whose every line is an addition, built from the new content in `input.content` — and
  its collapsed summary deliberately shows no `+N −M` count, because there is no old
  file to diff against. An honest write→old/new diff cannot be produced from pi data.
- **The table renderer has one built-in producer: `ls`.** None of pi's built-in tools
  emits a tabular structure; `ls` is the one naturally tabular built-in (one entry per
  row, a `/` suffix marking a directory), so it maps to `{type:'table', columns:['name','type']}`.
  The renderer itself is general, but a custom tool's `details` are shape-unstable and
  are deliberately not guessed at.
- **History doubles tool bytes, because a view mirrors content already in the messages.**
  Every tool call and result is relayed twice through history — once as the pi message,
  once as the normalized `tool` frame — so fewer messages fit `HISTORY_MAX_BYTES` in a
  tool-heavy session. Each payload is bounded on its own and the window keeps the newest
  turns. Since the window is now the **page size**, the visible cost is more pages to
  page through rather than older turns being unreachable: `truncated == true` offers the
  `Load older messages` control (see **History paging** below), and never a single
  oversized frame.
- **Tool frames are bounded to a quarter of the relay budget, and a drop is recovered,
  not lost.** `boundToolPayload` caps a tool payload at `TOOL_VIEW_MAX_BYTES` (64 KiB),
  a quarter of `MAX_RELAY_BYTES` (256 KiB). A frame that fills the budget is admitted
  only when no byte is outstanding, so a payload bounded at the budget itself would be
  dropped under *any* backlog; at a quarter it is dropped only under a severe one. A
  dropped `running` or `done` frame therefore leaves its row stale (or collapsed) under
  load — likely, not impossible — and the guarantee is the recovery path: the hub's
  **unbudgeted** `resync-required` makes the app re-request history, and the
  **unbudgeted** `snapshot` carries the annotated frames back (collapsed).
- **The 64 KiB bound now covers every view scalar, and a fresh truncated generic marker
  is the last resort.** `boundToolPayload` keeps the `view === undefined` guard for a
  viewless payload, applies the line cap, drops bulk in halves, then caps every view
  string field at 8 KiB with `truncated` set; if the payload is still over, it replaces
  `view` with a fresh `{type:'generic', truncated:true}`. The residual over-cap path is a
  pathologically long identity field (`name`) — pi-controlled and assumed short. The
  accepted behaviour behind the bound: `DiffLine.text` is not byte-capped, so a single
  huge line converges only by `dropHalfBulk` amputating the whole line, and two 40 KiB
  texts halve away rather than trim.
- **A pre-#6 `tool` frame without a `toolCallId` is rejected and dropped silently.** The
  decoder requires a non-empty `toolCallId` and `name` and a valid `status`; a frame in
  the old `{kind:'tool', name, status, args}` shape fails as `bad-field`, and the app
  drops any non-ok frame without a word. No live producer ever emitted that shape — the
  bridge emits no `tool` frame before this change — so the blast radius was the golden
  fixture and the contract, both updated. The version-skew fallback is narrower than
  "never drops": only a frame whose `view` is **absent or an unknown type** decodes and
  renders through the generic block.

## History paging

- **Loaded older pages do not survive a re-baseline.** `_onSnapshot` replaces the
  entries wholesale, so a reconnect, a `resync-required`, or a `leaf` move drops every
  page the user loaded and the transcript opens again at the newest page. The merged list
  shares no identity with a new branch, and after a leaf move the old pages belong to a
  different branch outright, so there is nothing to keep them attached to.
- **Retained pages grow without bound.** Every page the user asks for stays for the
  session, so paging back through a very long session grows the app's memory and the
  per-frame cost of deriving blocks from its merged entry list. There is no eviction;
  that is the deliberate price of fast re-scroll over a hard cap — pages the user asked
  for stay for the session.
- **Paging degrades to the static notice.** The `Load older messages` control is
  data-driven by `olderCursor`, which only a cursor-honouring bridge emits. An old hub
  rebuilds the snapshot and strips the extra fields; an old bridge emits neither
  `olderCursor` nor the routing `cursor`. Either way the app shows today's truncated
  notice and no control, and no capability advertises paging — a capability would lie in
  the new-hub/old-bridge skew, where the bridge cannot honour a cursor.
- **The scroll anchor is approximate.** The prepend correction uses a `maxScrollExtent`
  delta, so under `ListView.builder`'s lazy extent estimation it is approximate, and it
  **over-corrects when a page and a concurrent bottom append land in the same update** —
  the appended height inflates the measured insertion, so the anchored row can drift.
  And when the pre-prepend transcript **fitted** the viewport (`oldMax == 0`) the
  correction is skipped, because the viewport absorbs part of the insertion and the delta
  under-measures it: the view lands on the top of the newly loaded page with the previous
  context below the fold. Near-unreachable — a page that fits an ~800 px viewport can only
  be truncated when the whole 768 KiB budget went to entries that all collapsed to
  `{truncated:true,bytes}` markers. Recorded rather than fixed; the upgrade path is a
  keyed-anchor measurement (keep the old first block's id and correct by its measured
  render-position delta), which is also exact under concurrent appends.
- **The hub forwards each distinct cursor separately.** `pendingHistory` is keyed by
  cursor, so viewers asking for the same page coalesce while distinct cursors each ride
  their own forwarded `history-request`, costing the bridge a full `annotateToolViews` +
  projection. One authenticated viewer can mint distinct cursors with no cap, and a
  pending key lives until it is answered or its connection closes. The bound is named
  here, not hidden.
- **A leaf move or a compaction invalidates the anchor (the common case).**
  `buildContextEntries` follows the leaf, so a leaf move (or a compaction) shifts the
  annotated array; a cursor minted against the old path then fails its anchor check and
  the bridge silently answers a fresh baseline. That is the normal invalidation, not an
  error. The `leaf` handler re-requests the baseline, whose arrival clears any in-flight
  page for the session, so a late page cannot land on the new branch.
- **An unanswered page request is bounded by a 30-second timeout.** A live socket is not
  a live agent — the bridge returns silently when it has no `ctx` — so without the
  timeout an unanswered page would leave `Load older messages` disabled with single-flight
  blocking a retry. On expiry the app clears the pending key and the loading state, so the
  control returns to `Load older messages` and a retry works. One downgrade shape is
  outside the supported deploy matrix: a cursor sent to a bridge that no longer echoes
  cursors is dropped by the hub, so the tap simply does nothing until the timeout.
- **A re-register keeps the session's pending history keys.** A bridge takeover reuses the
  hub's `Session` object, including its cursor-keyed `pendingHistory` map, so a request
  left pending across the re-register is coalesced with a retry carrying the same cursor
  and the page is never forwarded — until the page timeout fires, or a request with a
  different key (a baseline) is sent. Pre-existing takeover shape, small window, named
  rather than hidden.

## App-started sessions


- **A spawned child cannot be killed before it registers.** `kill-session` is keyed by
  `sessionId`, which does not exist until the child's `register`; the app has no row
  for it either. The window is bounded by the registration deadline (60 s), after which
  the reaper kills it.
- **`pi` must be on the supervisor's `PATH`.** `spawn('pi', …)` resolves through the
  supervisor process's environment; a systemd/launchd-managed hub may not have it.
- **The bridge must be globally configured.** Production relies on the user's
  `<agent-dir>/settings.json` having the `pc/` package installed — `pi install
  <checkout>/pc`; the older `"extensions": ["…/pc/extensions"]` form still works
  too (both verified on the dev host). If neither is present, a spawned pi never
  registers; the registration reaper kills it and the start silently yields no row.
  The hermetic capstone proves the mechanism with an equivalent settings file.
- **The old-hub compatibility gate is a capability array, not a version.** The first
  post-auth `sessions` frame carries
  `capabilities: ["list-dirs","project-session","session-control","attachments"]`;
  a hub that predates them omits the field. The app then refuses `list-dirs` and
  `start-session{cwd}` **locally, without sending**, and the FAB falls back to the old
  direct start; the New/Fork menu items are likewise omitted rather than sent. This is
  load-bearing in two directions: an unknown viewer frame is closed `4003`, which the
  app treats as terminal (no reconnect), and an old hub ignores the extra `cwd`/`trust`
  fields and answers `ok` while spawning in a temp dir — a silent wrong-directory
  session. Neither can happen, because the new frames are never handed to a hub that
  cannot honour them.
- **The trust write is atomic but unlocked.** `saveTrustDecision` writes a sibling
  temp file and renames it over the store, so an interrupted write leaves the previous
  store intact rather than torn or empty (pi itself truncates in place). What is not
  taken: pi serializes its writes with `proper-lockfile` on `${trustPath}.lock`, so a
  concurrent `pi /trust` can still lose one update. Check pi's current lock options
  before adopting them, as that protocol is deliberately not replicated here to avoid
  a new runtime dependency.
- **A malformed trust store is refused loudly, not read as "no decision".** pi throws
  on malformed JSON, a non-object root, or a value that is not `true`/`false`/`null`,
  so a spawned child throws on the same file no matter what the hub does; this mirrors
  pi's documented strictness rather than a behaviour we test against pi. The hub-side
  half is verified: `readTrustStore` throws `TrustStoreError` and `hub.ts` answers the
  listing or the start with a `command-result` failure rather than `ok`. A missing file
  is `{}`, and a `null` value means "no decision" and the ancestor walk continues —
  both matching pi.
- **`PI_CODING_AGENT_DIR` is honoured (with `~` expansion).** The trust file is
  `<getAgentDir()>/trust.json` — `$PI_CODING_AGENT_DIR/trust.json` when set, else
  `~/.pi/agent/trust.json` — so a user with the variable set gets decisions written
  where their own pi reads them.
- **A symlink is offered only while its `realpath` stays under `$HOME`.** The browser
  realpaths each entry and drops any that resolves outside home, so a link cannot walk
  the listing out of the permitted tree.
- **The seven `removeDir` sites were audited, not sampled.** Every temp-dir removal in
  the spawner — `reap`, the sync-throw catch, `spawnedPid===undefined`, `closed`,
  `error` with no pid, `exit` with no pid, and `terminate` — is guarded by
  `Entry.owned`, and a test matrix asserts a chosen project directory survives every
  exit path. Only a hub-spawned temp dir is ever removed.
- **pi's "Trust parent folder" is not offered.** The app reduces pi's three-way prompt
  to Trust / Do not trust; granting a parent is done from the PC.
- **Spike: project-local `.pi/extensions` load headlessly under `--approve`, not
  `--no-approve`.** A spike extension in a temp project wrote its marker file under
  `pi --mode rpc --approve` and did not under `--no-approve`, so the project spawn
  passes `--approve` exactly when the effective trust decision is true (`--no-approve`
  otherwise, per `defaultProjectArgs` in `pc/src/hub/spawner.ts`). Hand-run spike on
  the dev host with `pi` 0.87.1; no committed script or test pins it.
- **A project session is saved, but only once the agent has replied.** Project spawns
  drop `--no-session`, so pi persists the session under
  `~/.pi/agent/sessions/--<encoded-cwd>--/`, and it can be continued on the PC with
  `pi --continue` (the most recent session for that cwd) or `pi --resume` (the picker)
  run from that directory — `/resume` does the same inside a running pi, while `/tree`
  only navigates branches of the session you are already in. The trust decision the
  phone wrote applies to that PC run too, so the same project config loads. The caveat:
  pi buffers entries in memory until the first *assistant* message exists, so a session
  started from the phone and killed before the agent answers leaves the session
  *directory* and no `.jsonl` — nothing to resume. (An earlier version of this note
  read "persists no session file" from a spike that started pi and stopped it without
  ever sending a prompt; that was a methodology artifact, not the behaviour — the
  hand-run spike recorded nothing because there was no turn. Verified on the device:
  an app-started project session does resume on the PC.)
- **The `.pi` trust prompt follows pi's exact gate, not the presence of `.pi`.** A
  resource-free project — including one whose only `.pi` entry is `plans/`, as in this
  repo — starts with no prompt, because pi itself asks only when `.pi/settings.json`,
  `.pi/extensions`, `.pi/skills`, `.pi/prompts`, `.pi/themes`, `.pi/SYSTEM.md`,
  `.pi/APPEND_SYSTEM.md`, or a non-user `.agents/skills` directory exists.
  `AGENTS.md` never triggers it: context files load whether the project is trusted or
  not.

## Session control

- **Sixteen of pi's built-in commands are unreachable from the app:** `settings`,
  `scoped-models`, `export`, `import`, `share`, `bug`, `copy`, `session`, `changelog`,
  `hotkeys`, `clone`, `trust`, `login`, `logout`, `reload`, `quit`. They are PC-console
  or terminal concerns — a settings editor, an export/import pipeline, a login flow, a
  quit key — with no meaning on a phone. pi excludes them from the command list it
  exposes to extensions, so the bridge cannot offer them; typing one still reaches the
  model as prose (the built-ins trap above). Not built.
- **`/resume` is out of scope (issue [#28](https://github.com/Tako88/PI-Droid/issues/28)).**
  A session list is not reachable from an extension: `SessionManager.list`/`listAll` are
  statics, and the `ctx.sessionManager` the bridge holds is a `ReadonlySessionManager`
  exposing only `getSessionDir()`. The bridge cannot import pi, so the list cannot be
  read. Tracked as an issue rather than silently dropped.
- **The Tree picker navigates without summarizing.** v1 mirrors pi's `/tree` minus the
  summary step: moving the leaf does not summarize the branch you leave, so nothing new
  is written to the session file. pi itself defaults to "No summary" but also offers
  "Summarize" and a custom prompt; neither is offered here. Reason: the summary is a
  model call whose result has no phone rendering (below), and v1 is deliberately the
  navigation-only half.
- **The tree picker caps its indentation at six levels.** pi's terminal tree draws as
  many branch levels as a branch needs and clips horizontally where it runs out of
  room; a phone bottom sheet cannot scroll sideways, so past six 16dp steps (96dp) the
  label would have nothing left on a 360dp sheet. The branch rule above the cap is pi's
  own — a child steps in only where the history branched, so a straight conversation
  renders flat however long it is.
- **The tree is the message skeleton, not the whole session file.** Only `user` and
  `assistant` message entries are offered as navigation targets. Tool results, compaction
  entries, branch summaries, `session_info` and `model_change` are not, because the
  bridge's tree projection emits a node only for a `message` entry whose role is user or
  assistant. pi's own `/tree` can navigate to the omitted entries. The flip side: an
  assistant turn that ran tools before writing any prose has no text parts, but it is no
  longer mislabelled as an empty message — its node is labelled `(tool calls: ls, grep)`
  (the tool names it called, deduplicated, first-seen order), or `(thinking)` when it only
  thought, and only a turn with neither stays empty. A turn that has text is unchanged.
- **A branch summary on the path has no phone rendering.** A summary written by a
  PC-side `/tree` is relayed as the raw `branch_summary` entry it is — it becomes the
  leaf, so it stays on the active branch — but the app's block model emits no row for its
  `branchSummary` role (nor for a `compactionSummary`), so the summary does not appear in
  the transcript at all. With none of pi's own summary entry in the picker either (the
  skeleton above), a summary is readable only by opening the session on the PC. Not
  built.
- **The composer prefill is the projection's flattened text, not pi's raw editor text.**
  Tapping a user node fills an empty composer with the text the tree projection emitted
  (`projectedMessageText`), which joins a message's text parts and marks every non-text
  part as `[image]`. A message that was an image with a caption therefore prefills the
  caption plus `[image]`, not the original parts — and re-editing it from the phone sends
  that flattened text. pi prefills its own editor with the raw content. The rule for
  *when* to prefill matches pi: a user node only, and only into an empty composer.
- **Navigating is refused while pi is working** (streaming or compacting), with a visible
  error. Reason: pi's own `/tree` aborts the running turn and then navigates, but an
  accidental tap on the phone should not discard a turn the user did not mean to cancel,
  and the phone cannot see streaming state to warn about it. The refusal is a deliberate
  deviation from pi, read at dispatch.
- **A tap on a point pi has already left ends silently.** If the leaf moved between the
  picker's `listTree` and the tap (a PC-side `/tree`, or a turn landing), pi early-returns
  `{cancelled:false}` before emitting, so the tap produces no `leaf` event: nothing
  navigates, nothing is prefilled, and no message appears — the picker's check mark was
  stale. The user re-opens the picker for a fresh list.
- **Two navigations inside one round-trip can both be answered by one snapshot.** The hub
  coalesces pending `history-request`s **per cursor**: two cursorless baseline requests, as
  here, join one forwarded request and are answered together with the history the bridge
  returns, so a second move issued while the first request is pending joins it (a page
  request carrying a different cursor is forwarded separately — see **History paging**
  below). The screen can briefly show the earlier branch and heals on the next re-baseline
  (the next leaf event, turn or reconnect). Rare.
- **A PC-side navigation mid-turn discards the phone's in-flight streamed text.** A leaf
  event re-requests history, and the snapshot replaces the entries wholesale, dropping the
  live `streamingText`. The turn is over by the time pi emits the leaf, so the committed
  content is right and only a visible jump results.
- **A `leaf` event is attributed to whichever session the app has active.** Relayed event
  frames carry no session id, so the client keys the move — and the history request it
  triggers — on the active session. This is the same one-session-model race every relayed
  event has (the `usage`-frame case above); revisiting the session re-subscribes and
  requests history, which heals it.
- **A successful `sessionNew`/`sessionFork` ack is not the confirmation.** The ack means
  *"the bridge accepted this and handed it to pi"* (`ok:true`), not that the session was
  replaced. The confirmation is the **replacement itself** — the old session id goes away
  and a successor registers naming it — which is what the app actually follows. An ack
  alone is never treated as success.
- **A cancelled replacement surfaces as an error notice, not a silent ack.**
  `newSession`/`fork` resolve `{cancelled:true}` when a `session_before_switch` or
  `session_before_fork` handler cancels, and the bridge emits a `status` error for it, so
  the phone sees a message rather than an ack over a replacement that never happened.
- **A PC-side `/tree` now reaches the phone, but only a build that has the signal.**
  The bridge forwards pi's `session_tree` event as a `leaf` frame, so a `/tree` run on
  the PC re-baselines the phone's transcript to the new branch. An app or bridge that
  predates the `leaf` kind still goes stale on it — an old app drops the frame, and an
  old hub closes the bridge (`4002`) before it is forwarded, so the deploy gate below
  applies. The move itself is real either way; only the phone's view lags.
- **A fork target can go stale between the list and the tap, and there is no retry.** An
  entry invalidated by a turn landing between `listTree` and the tap is refused at
  dispatch as `unknown entry`, which the app shows as a SnackBar; the user re-opens the
  picker for a fresh list. Deliberately no auto-retry — a silent retry against a moved
  target is worse than a visible refusal.
- **A replacement that never arrives gives up after 15 seconds.** If the bridge dies
  between the old session's shutdown and the successor's register, the app stops waiting
  after a 15 s replacement timer and falls back to the session list, with the visible
  error `the session did not come back`. Bounded, not silent.
- **The `ok` for a replacement is optimistic.** While the follow is armed, the app
  completes a still-outstanding `sessionNew`/`sessionFork` as `ok:true` on the old
  session's `session-gone` — the earliest witness, chosen so the two possible arrival
  orders converge — even though the bridge could die inside the 15 s window before the
  successor registers. The 15 s timeout still runs and returns the UI to the session
  list, so the wrong state is bounded, not permanent.
- **A `command-result` can be dropped under hub backpressure.** The hub relays command
  replies through its budgeted viewer path, so a result can be dropped when the byte
  budget is exhausted. The app's own 30 s command timeout is the backstop; for a
  replacement the follow is keyed on the `sessions` push rather than the ack, so the
  loss does not by itself strand the follow. Pre-existing hub behaviour, not specific to
  session control.
- **A future extension registering `pi-droid-session` would make the trigger fall
  through to the model.** pi disambiguates a duplicate command name as `name:occurrence`,
  while the bridge triggers the bare `/pi-droid-session …`; if another extension ever
  registered that name the bare lookup would miss, the prompt would reach the model as
  prose, and the bridge would already have acked `ok:true`. **Verified clear today** — no
  extension in this deployment registers the name — and the internal command is filtered
  out of the app's `/` overlay, so it is never offered back. A name collision would be a
  silent wrong-state ack, which is why it is recorded rather than assumed away.
- **The internal command is visible to a PC terminal user.** `pi-droid-session` appears
  in pi's own command list inside a terminal, because pi concatenates every registered
  extension command; the bridge filters it out of the **app's** `/` overlay only. Running
  it from the PC is harmless (it is the same action the phone triggers), but a terminal
  user will see a command the app does not offer.
- **Deploy gate: an APK rebuild AND pi `/reload` AND a hub restart.** The four new names
  (`listTree`, `sessionNew`, `sessionTree`, `sessionFork`) are in the hub's command
  allowlist and `session-control` is a new capability, both read at import, so an old hub
  refuses the new commands; the bridge is read from disk by pi, so a running pi needs
  `/reload` (or a restart); and the menu items and follow logic ship in the app. An old
  app ignores the new `replacesSessionId` field and the capability, so it is never
  offered the items. **Tree navigation adds a harder reason for the restart:** the leaf
  signal is a new event payload kind, and the hub validates a relayed event's `kind`
  against `EVENT_PAYLOAD_KINDS` (read at import) and closes the bridge's socket `4002` on
  an unknown one. A hub that predates `leaf` therefore drops the bridge's connection on
  the first navigation — a PC-side `/tree` included, not just a phone tap — and the phone
  never re-baselines. This is the case the hub's relay being "opaque to events" does
  **not** cover: the relay passes the payload through untouched, but the *kind* is a
  closed set enforced at runtime. The `leafId` field on the `listTree` `command-result`
  is genuinely safe and needs nothing; only the event kind forces the restart.

## Notifications

- **The transcript ⋮ menu offers only Default and Muted, never Force-on.** The toggle
  lives in the transcript, so reaching it already engages the session — a force-on switch
  would answer a question the open transcript has already answered.
- **A muted session keeps its mute through a `/new`/`/fork` successor.** The flag is
  migrated to the new session id along with the engagement, so the successor inherits it;
  intended, because the successor is the same conversation continued.
- **An app-started session counts as engaged from the moment it starts**, so it can notify
  even before its transcript is opened. Deliberate: `origin == 'app'` is treated as
  engagement because starting a session takes you into it, and a quick session that
  settles before the transcript finishes opening would otherwise be silent.
- **Changing hubs does not clear the stored notify preference.** Session ids come from
  pi's session-file header, so a session file synced to two machines could in principle
  carry a mute across; leaving it is deliberate, because pruning on a hub change would
  forget the override for a session resumed later. The LRU cap eventually evicts the
  oldest entries after a change of hubs.
- **Muting at the instant a session is replaced can write the mute to the predecessor.**
  The menu item toggles whichever id it was built for, so a `/new`/`/fork` landing between
  build and tap migrates the flag to the successor while the tap writes the old id, and
  one tap may appear not to stick. No crash.

## Pairing

- **A hub has exactly one outstanding ticket.** `ticket.issue()` replaces the previous
  ticket, so minting a second code (via `pair` or `kill -USR1`) immediately invalidates the
  first. Pre-existing, but the QR makes it more likely to be noticed: print one code at a
  time and pair with it before printing another.
- **The QR carries a 5-minute, single-use ticket, never the token.** The QR is only as
  sensitive as the code it encodes; it cannot be replayed after pairing or after the TTL.
- **`--no-lan` advertises no addresses at all.** The QR then carries the code only, and the
  app must be given the address by hand. A LAN hub with no RFC1918 address (for example a
  public-IP-only host) advertises nothing for the same reason.
- **The control socket's only protection is filesystem permissions**: the `0700`
  `<runtimeDir>/pi-droid` directory plus a `0600` `control.sock`. There is no protocol-level
  authentication, deliberately — any same-UID process can already read the token file, so
  the socket adds no exposure beyond that.
- **A `SIGKILL`ed hub leaves its `control.sock` behind.** The next `serve` reclaims the stale
  file at the rename step — it listens on a unique temp path first, then renames that socket
  onto the canonical path — so `pair` sees `ECONNREFUSED` (and the dead discovery pid reads as
  "no hub") until then.
- **`pair` is same-machine only.** It talks over a Unix socket, so it cannot mint a code
  for a hub on another host; there the `kill -USR1` route (or running `pair` on that host)
  is still the way.

## QR scanning

- **A forced candidate is a race *preference*, not a pin.** The picker dials every stored
  candidate in parallel and adopts the tapped address when it answers; if the preferred
  candidate fails or does not answer within `_candidateConnectTimeout` (2 s), a held
  non-preferred success is adopted instead, so the hold can add up to a 2-second stall on a
  forced tap. Switching preference **after** a successful connection is not possible in
  place — it needs **Change hub**, because the picker renders only on the pairing screen.
  The whole list is retained, so a forced-home tap does not break the tailnet reconnect.
- **A failed scan-pair can only be retried while the same ticket is valid and unburned.**
  The scanned ticket is single-use and lives 5 minutes: a successful scan whose race
  authenticates but is rejected, or that burns the ticket's five failed attempts, cannot be
  retried silently — the only recovery is a **fresh code** (a new scan, or the hub's printed
  code retyped into the manual form). The client's pre-existing background reconnect keeps
  presenting the spent ticket until the user re-pairs, so the pairing screen deliberately
  clears the code and requires a new code (a fresh scan, or the hub's printed code retyped
  into the manual form) rather than appearing to resubmit the same one. A good ticket and a
  dead one are indistinguishable to the app: a bad ticket gets silence (the client's auth
  watchdog fires), not a machine-readable refusal.
- **The camera permission and its denial UI belong to `mobile_scanner`.** Declaring
  `CAMERA` in the app manifest does not prompt; the plugin auto-requests it when a scan
  starts and surfaces a denial through its `errorBuilder`, which the app renders in-route
  with a Close button. `minSdk 23` did not force a floor bump (the app's is 24) and
  `compileSdk 36` is satisfied. The **bundled ML Kit backend is the default**, so scanning
  works offline, at a **+3–10 MB APK** cost; the unbundled (Play Services) backend is opt-in
  via `android/gradle.properties`.
- **The candidate list lives under a new key, so a downgrade cannot decode garbage.**
  `pi_droid_endpoints` holds the newline-joined list while `pi_droid_endpoint` keeps its
  original single-`host:port` format; the new build writes the *first* candidate to the
  legacy key and never the list. An older build therefore reads a single endpoint it
  understands, or nothing when that key is unset and re-pairs cleanly — it never sees the
  newline string, so it never runs it through `lastIndexOf(':')` to produce a
  newline-bearing garbage host.

## Navigation

- **The predictive preview is an Android 14+ default; Android 13 needs the developer-option
  toggle, and API < 33 shows no preview at all.** The transcript route and the manifest
  opt-in are what make the preview possible on capable OSes; on older ones back still pops
  the route, just without the peek.
- **Dialogs and bottom sheets over the transcript are not predictive.** They carry no
  predictive transition, so back dismisses them through the non-predictive fallback,
  exactly as before.
- **A session that disappears while a dialog or sheet is open leaves that overlay over the
  session list.** The state-driven removal uses `removeRoute`, which cannot pop the overlay,
  so the dialog survives and any action taken in it is sent for a session that is gone. This
  is today's behaviour too — the migration preserves it — and it is recorded rather than
  fixed because dismissing a user's dialog on a background event is its own decision.
- **The transcript route's presence is tracked by a shell field, not by the Navigator.**
  Only the transcript route is tracked; the folder browser is a separate route, and any
  future code that pops the transcript outside `_syncTranscriptRoute` must keep
  `_transcriptRoute` in sync.
- **A composer draft is still not per-session.** `_attachment` is cleared on a session
  change but the draft text is not, so a draft typed in one session is still in the box in
  another. The navigation migration preserves this deliberately; fixing it is its own
  decision.

## Appearance

The app is tinted with pi's own palette (`app/lib/ui/theme.dart`): pi's built-in dark and
light themes resolved to hex, mapped onto a Material `ColorScheme` plus a `PiRoles`
theme extension. Each limit below is a knowing deviation from pi's theme files, and each
was measured rather than assumed.

- **The light palette is derived, because pi's is broadly sub-AA.** Contrast was measured
  for every (role, surface) pair the renderers actually draw. pi's light theme fails at
  AA for `muted` (4.32:1 on its own page), `mdHeading` (4.37), `mdLink` (4.25), `dim`
  (2.81 — below even the 3:1 bar for a rule) and the whole thinking ramp (1.57–2.44), and
  `toolOutput` fails in *both* themes (4.46:1 on `toolSuccessBg`). Those values are
  darkened (light) or lightened (dark) toward `text` until they clear 4.5:1 as text, or
  3:1 as a rule, against the worst surface each is used on. The hue is unchanged; only
  lightness moves. pi's *generated* `system` theme enforces exactly this floor internally
  (`TEXT_MINIMUM_WCAG_CONTRAST = 4.5`), so this is pi's intent rather than a departure
  from it. A property test in `app/test/ui/theme_test.dart` pins the contrast floor over
  a hand-written table of pairs — a pair missing from that table is unguarded.
- **The dark page and card are darker than pi's export colours.** `#21252c` and
  `#282c34` become `#12141a` and `#191c22`. pi's dark theme declares **no background at
  all** (its `text` token is the empty string, meaning the terminal's own default), so
  `#21252c` is only the colour pi guesses for an HTML export page — and on a phone it
  reads as a washed-out grey over most of the screen. The hue cast and the card-to-page
  delta are preserved; only the level moves.
- **The light thinking ramp is pi's *dark* ramp.** pi's light ramp fails the 3:1
  graphical bar at every level (1.57–2.44), so a thinking row would be invisible on
  light. The light palette therefore reuses pi's dark ramp values (3.17–4.31 there), with
  `thinkingMax` nudged to reach 3:1.
- **The thinking ramp is a rule-and-icon colour, never text.** Its values are 3–4.5:1, so
  the seven level names are printed in words (`Thinking · high`) rather than coloured by
  it. It also never colours a *rule* on a thinking row: `thinkingHigh` is the same violet
  as the accent, so a ramp-coloured rule made a thinking row and the user's row read
  alike. Thinking rules are neutral; violet means "you". The ramp does colour the
  **composer band's** two rules, because that is what pi itself does with its editor
  border — so at `off` or `minimal` the band is grey, which may read as disabled rather
  than quiet. Accepted rather than fixed: pi's editor is always what you are looking at,
  and the app's composer is not.
- **`dim` is never used for text.** It is rules, dividers and handles only — it sits
  under 4.5:1 on both themes. `muted` is the lowest role fit for words.
- **Roboto is the body face.** Type is platform fonts only: the platform mono face for
  anything the machine produced or named (tool names and arguments, command output,
  diffs, file paths, session ids, the pairing code, the context reading), and the
  platform sans for prose. A monospace/sans split is pi's own shape, but a *distinctive*
  body face is not achieved — bundling one is a one-file change when wanted.
- **The app follows the phone's light/dark setting, not pi's configured theme.** pi's
  theme role is not on the wire, and putting it there would be a protocol change for no
  real gain. So a phone in light mode shows pi's light palette even when pi itself is
  running `dark`.
