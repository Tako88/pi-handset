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
  `_onPaired` has no generation guard, and the shell persists `_pendingEndpoint` on
  `connected`, so a frame already queued when a new submit lands can pair host B's
  endpoint with host A's token. The normal path closes the socket first, so the window
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
  turns, so the visible cost is older turns being dropped (`truncated == true`), not a
  single oversized frame.
- **Tool frames are bounded to a quarter of the relay budget, and a drop is recovered,
  not lost.** `boundToolPayload` caps a tool payload at `TOOL_VIEW_MAX_BYTES` (64 KiB),
  a quarter of `MAX_RELAY_BYTES` (256 KiB). A frame that fills the budget is admitted
  only when no byte is outstanding, so a payload bounded at the budget itself would be
  dropped under *any* backlog; at a quarter it is dropped only under a severe one. A
  dropped `running` or `done` frame therefore leaves its row stale (or collapsed) under
  load — likely, not impossible — and the guarantee is the recovery path: the hub's
  **unbudgeted** `resync-required` makes the app re-request history, and the
  **unbudgeted** `snapshot` carries the annotated frames back (collapsed).
- **A pre-#6 `tool` frame without a `toolCallId` is rejected and dropped silently.** The
  decoder requires a non-empty `toolCallId` and `name` and a valid `status`; a frame in
  the old `{kind:'tool', name, status, args}` shape fails as `bad-field`, and the app
  drops any non-ok frame without a word. No live producer ever emitted that shape — the
  bridge emits no `tool` frame before this change — so the blast radius was the golden
  fixture and the contract, both updated. The version-skew fallback is narrower than
  "never drops": only a frame whose `view` is **absent or an unknown type** decodes and
  renders through the generic block.

## App-started sessions


- **A spawned child cannot be killed before it registers.** `kill-session` is keyed by
  `sessionId`, which does not exist until the child's `register`; the app has no row
  for it either. The window is bounded by the registration deadline (60 s), after which
  the reaper kills it.
- **`pi` must be on the supervisor's `PATH`.** `spawn('pi', …)` resolves through the
  supervisor process's environment; a systemd/launchd-managed hub may not have it.
- **The bridge must be globally configured.** Production relies on the user's
  `<agent-dir>/settings.json` listing `pc/extensions` (verified on the dev host). If it
  does not, a spawned pi never registers; the registration reaper kills it and the
  start silently yields no row. The hermetic capstone proves the mechanism with an
  equivalent settings file.
- **The old-hub compatibility gate is a capability array, not a version.** The first
  post-auth `sessions` frame carries `capabilities: ["list-dirs","project-session"]`; a
  hub that predates them omits the field. The app then refuses `list-dirs` and
  `start-session{cwd}` **locally, without sending**, and the FAB falls back to the old
  direct start. This is load-bearing in two directions: an unknown viewer frame is
  closed `4003`, which the app treats as terminal (no reconnect), and an old hub
  ignores the extra `cwd`/`trust` fields and answers `ok` while spawning in a temp dir
  — a silent wrong-directory session. Neither can happen, because the new frames are
  never handed to a hub that cannot honour them.
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
