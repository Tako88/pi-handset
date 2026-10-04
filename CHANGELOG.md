# Changelog

Notable changes to pi-droid. Versions are one semver shared by the app and the PC
package; `PROTOCOL_VERSION` is a separate integer, bumped only when the wire breaks.

## [0.1.0] - 2026-10-04

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

[0.1.0]: https://github.com/Tako88/PI-Droid/releases/tag/v0.1.0
[#50]: https://github.com/Tako88/PI-Droid/issues/50
