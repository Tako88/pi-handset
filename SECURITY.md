# Reporting a security issue

Please **do not** open a public issue for a vulnerability. Use
[private vulnerability reporting](https://github.com/Tako88/pi-handset/security/advisories/new)
instead — it opens a draft advisory that only the maintainer can see.

Include enough to reproduce it: which version (a release tag or a commit), what an
attacker gains, and the steps. A short reproduction is worth more than a long one.

## In scope

The hub and the bridge on the PC (`pc/`) and the Android client (`app/`).

## Already known

Some things that look like vulnerabilities are documented, deliberate trade-offs rather
than defects. Please read [`docs/known-limits.md`](docs/known-limits.md) first — the two
that matter most:

- **The hub serves plain `ws://`.** Anything that can read the connection's frames holds
  the pairing token and everything it grants. A tailnet, rather than a network you share,
  is the intended deployment.
- **One pairing token is shared by every device, and there is no way to rotate it**
  (issue [#66](https://github.com/Tako88/pi-handset/issues/66)).

## Supported versions

Only the latest release is supported.
