# pi-handset

An Android chat client for [pi](https://github.com/earendil-works/pi). pi runs on
your PC; this puts it in your pocket — read a long reply from the sofa, check on an
agent that has been working for twenty minutes, or send the next instruction without
walking back to the desk.

It is not a terminal mirror, and not a chat wrapper. A hub on the PC attaches to the
pi sessions already running there, and the phone shows the real thing: the same
transcript, the same thinking, the same tool calls, rendered properly and updating
live. Pair once over your LAN or a tailnet, and every `pi` you start afterwards shows
up in the list. The hub serves plain `ws://`, so prefer a tailnet on any network you do
not own — see [`docs/known-limits.md`](docs/known-limits.md#pairing).

`pc/` is Node + TypeScript, `app/` is Flutter + Dart, and `protocol/` holds the golden
fixtures both sides assert against.

<!-- Screenshot / short video of the transcript goes here. -->

## What it does

- **Reads and writes pi sessions from the phone.** The transcript is a document: your
  messages, the agent's thinking, tool calls and their results, rendered as typed
  blocks rather than a wall of text.
- **Find text in the transcript.** A search button in the app bar matches text in the
  transcript rows already loaded and steps through the hits, tinting each matching row.
- **Streams live.** Replies arrive token by token and the reasoning streams into its
  own row above the reply. A content-free phase frame means a slow first token is
  never mislabelled as thinking.
- **Renders tool calls by kind.** A diff for `edit`/`write`, a file range for `read`,
  a command and merged output for `bash`, grouped matches for `grep`/`find`, a table
  for `ls`, and a fallback for anything else.
- **A session menu** — New, Fork, Tree, Compact, Rename, thinking level, and a model
  picker limited to the providers you actually have credentials for.
- **Slash commands.** Typing `/` completes the session's real commands — prompt
  templates, extension commands, skills — and runs them in pi rather than sending the
  text to the model.
- **Start a session in a project folder.** Browse the PC's home directory and start a
  `pi` that runs in the chosen folder, so its session is saved under that project and
  `pi --continue` picks it up.
- **Pairing that sticks.** Scan a QR or type a code once; the phone keeps a token, and
  restarting the hub does not de-pair it.
- **Images, both ways.** Assistant and tool images render, and the composer can send
  one downscaled gallery image with a caption.
- **Looks like pi.** The palette is pi's own, light and dark, following the phone's
  setting — with measured contrast fixes where pi's terminal palette is sub-AA.
- **Android niceties**: predictive back, and notifications for the sessions you have
  open.

What is not built — and what is deliberately left out — is in the
[issue tracker](https://github.com/Tako88/pi-handset/issues) and
[`docs/known-limits.md`](docs/known-limits.md).

## Quick start

You need [pi](https://github.com/earendil-works/pi) and Node ≥ 22.19 on the PC. To
build the app you also need Flutter 3.47.5, the Android SDK, and a JDK; the exact
setup used here is in [`docs/development.md`](docs/development.md). The phone and the
PC have to be able to reach each other. A tailnet is preferred over a shared network:
the hub serves plain `ws://`, so anything that can read the connection's frames has the
pairing token and everything it grants.

```sh
git clone https://github.com/Tako88/pi-handset
cd pi-handset

pi install ./pc                 # load the bridge into every pi you start
node pc/src/cli/main.ts serve   # start the hub (port 8787 by default)
node pc/src/cli/main.ts pair    # print a pairing code and a QR
```

Then build and install the app:

```sh
cd app
flutter build apk --profile
adb install -r build/app/outputs/flutter-apk/app-profile.apk
```

Open the app and scan the QR, or type the address and code. From then on, any `pi` you
start registers itself and its session appears in the list.

Notes for the first run:

- The code is single-use, and dies after 5 minutes or 5 failed attempts. `pair` talks
  to the running hub over a `0600` Unix socket, so it only works on the same machine.
- The token is stored per phone, so pairing happens once. A *changed signing key* or an
  `adb uninstall` loses it; a plain `adb install -r` or a hub restart does not.
- The QR encodes a `pihandset://pair` URI carrying the code and every address the hub can
  advertise; with `--no-lan` it carries the code alone. `kill -USR1 <pid>` still prints a
  code, but `pair` is the supported path.
- **If pairing just spins, suspect the firewall.** With `ufw` on its default `DROP`
  input policy the phone's connection to port 8787 over the LAN is silently dropped;
  Tailscale is not. Test it **from the phone** — the PC connecting to itself proves
  nothing:

  ```sh
  adb shell 'timeout 5 toybox nc 192.168.1.100 8787 < /dev/null; echo exit=$?'
  # exit=0 -> connected;  exit=124 -> dropped (the firewall)
  ```

  Then open the LAN path, scoped to the subnet rather than the world:

  ```sh
  sudo ufw allow from 192.168.1.0/24 to any port 8787 proto tcp
  ```

## How it works

Three pieces, and the phone only ever talks to the first:

| Piece | Runs | What it is |
|---|---|---|
| **Hub** | the PC | one process: two WebSocket listeners, the session registry, the relay, and the spawner for app-started sessions |
| **Bridge** | inside each running `pi` | a pi extension that registers the session, normalizes pi's events, and runs commands |
| **App** | the phone | the Dart client and the Flutter UI |

```
phone ──WebSocket (viewer port 8787)──▶ hub ◀──WebSocket── bridge (inside pi)
```

- The hub listens on a **viewer** port (bound for phones) and an **agent** port (bound
  to loopback only), and each listener advertises different capabilities. Pairing
  codes are minted on demand over a `0600` Unix control socket.
- The agent port is **ephemeral** and written to a discovery file; the bridge finds it
  there, which is why a hub restart does not need the phone to re-pair.
- Every frame is a `{protocolVersion, type, payload}` object, and both sides decode it
  from the **same golden JSON fixtures** in `protocol/`, so a field-name drift is a
  test failure rather than a subtle runtime bug.

Deployment has three independent units — an APK rebuild, a pi `/reload`, and a hub
restart — and a change touches only the ones it has to. Which is which, and the
reasoning behind the design, are in [`docs/status.md`](docs/status.md) and
[`docs/decisions.md`](docs/decisions.md).

## Status

Both sides are built and tested, and the whole path has been exercised for real: a real
`pi`, a real hub, the real Dart client, and the app on a phone driving a live model.

| | `pc/` (Node + TypeScript) | `app/` (Flutter + Dart) |
|---|---|---|
| Suite | `npm test` | `flutter test` |
| Static gate | `tsc --noEmit` clean | `flutter analyze` clean |
| Product code | hub, protocol codec, pi bridge | protocol codec, client, UI |

What is built, what each change costs to deploy, and what the manual passes caught that
the suites could not: [`docs/status.md`](docs/status.md).

## Repo layout

```
pc/         Node + TypeScript — supervisor, pi extension, protocol codec
app/        Flutter + Dart — the Android client
protocol/   shared golden JSON fixtures, asserted by BOTH suites
docs/       status, decisions, development, known limits
AGENTS.md   rules and conventions for contributors and coding agents
```

Two first-class halves; neither owns the repo root. **There is deliberately no manifest
at the root**, so every command runs from inside its own side — `npm test` at the root
fails with ENOENT by design, not by accident.

## Development

```sh
cd pc  && npm test && npm run lint && npm run typecheck   # suite, lint, type gate
cd app && flutter test && flutter analyze                 # suite, analyzer
```

Both gates on both sides must be green before anything is done, and CI runs the same
five commands on every push to `develop` and every pull request against it
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)). Toolchain setup, the
paid live-model test, the emulator notes and the deeper install details are in
[`docs/development.md`](docs/development.md); the rules are in
[`AGENTS.md`](AGENTS.md).

## Further reading

- [`docs/status.md`](docs/status.md) — the engineering record: what is built, the deploy
  units, and what the manual passes found.
- [`docs/decisions.md`](docs/decisions.md) — why the code looks the way it does.
- [`docs/development.md`](docs/development.md) — toolchain, tests, install notes.
- [`docs/known-limits.md`](docs/known-limits.md) — what the app deliberately does not
  do, each with its reason.
- [`AGENTS.md`](AGENTS.md) — TDD method, test layout, definition of done.
