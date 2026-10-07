# Changelog

Notable changes to pi-handset. Versions are one semver shared by the app and the PC
package; `PROTOCOL_VERSION` is a separate integer, bumped only when the wire breaks.

## 0.2.0 - 2026-10-07

The app, the hub and the bridge are now `pi-handset`: the application id, the Dart
package name, the four secure-storage keys, the hub's token file, its environment
variables and its runtime paths all move. The wire is unchanged — `PROTOCOL_VERSION`
stays 1, and no frame carries the name.

- **Find text in the transcript** — a search field in the transcript bar steps through
  the matches the app holds and tints the row of the current one.
- **Copy a message** — a row's copy action puts that message's exact source text on the
  clipboard, and the transcript is selectable as well.
- **A long session opens in a bounded window** — the first frame renders the newest
  blocks instead of the whole loaded page, and reaching the top reveals more, anchored so
  the row being read does not move.
- **A session started from the app appears at once** — a pending row shows as soon as
  the child is spawned and becomes the session when it registers; if the child dies
  first, the row is replaced by the reason it failed.
- **An icon and a dark launch window** — the launcher no longer shows the package name,
  and a cold start no longer flashes white.
- **Fixed** — a hub stopped during startup no longer leaves its lock, control socket and
  discovery record behind, and `pi` children orphaned by a hard-killed hub are reaped on
  the next start.
- **Build** — release APKs are signed with a real key and the release path refuses to
  build without it; CI runs both suites and every static gate on each push; a shared
  contract pins the protocol numbers both halves use.

## 0.1.0 - 2026-10-04

First release.

- **App** — session list, a live transcript with thinking and tool blocks, a compose
  bar, a session menu (compact, rename, thinking level, model), a folder browser for
  starting a project session, pairing by scanning a QR or typing a code, image
  rendering and sending, notifications, and predictive back.
- **Hub** — session registry and spawner, paged history, a Unix control socket for
  minting pairing codes, and per-connection resource bounds.
- **Bridge** — a pi extension that registers the running session with the hub and
  relays normalized events.
- **Install** — load the bridge with `pi install <checkout>/pc`; the app is a Flutter
  profile APK. There is no published package yet ([#50]).

[#50]: https://github.com/Tako88/pi-handset/issues/50
