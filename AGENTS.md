# AGENTS.md

## Project

pi-droid — an Android chat client for pi. A supervisor and a pi extension run on
the PC; a native Android client talks to them.

## Repo layout

Two first-class halves and a shared contract directory. Neither half owns the repo
root, so **every command runs from inside its own side**:

```
pc/         Node + TypeScript — supervisor, pi extension, protocol codec
app/        Flutter + Dart — the Android client
protocol/   shared golden JSON fixtures, asserted by BOTH suites
```

There is deliberately no manifest at the repo root. `npm test` at the root fails
ENOENT; that is expected, not a bug.

## Method: TDD, always

We develop test-first. No production code is written before a failing test demands it.

### The loop

1. **Red** — write the smallest test that expresses the next behavior. Run it. Watch
   it fail for the right reason.
2. **Green** — write the minimum code to pass. Nothing extra.
3. **Refactor** — clean up with the tests green.

### The three laws

1. Write no production code until a failing test requires it.
2. Write no more of a test than is needed to fail (a compile/type error counts).
3. Write no more production code than is needed to pass.

### Rules

- A test never seen failing is not a test. Run it red first.
- **A gate never seen failing is not a gate.** When you add a static check
  (`typecheck`, `analyze`, a linter), inject one fault, watch the gate reject it,
  then revert. A green gate proves nothing on its own.
- One behavior per test. Name the behavior, not the function.
- A bug fix starts with a regression test that reproduces the bug, written *before*
  the fix.
- Tests are the spec. If a behavior matters and is untested, it is not done.
- Never delete or weaken a test to make a change pass. Fix the code, or change the
  test deliberately and say so.
- Keep tests deterministic. No sleeps to "make it work"; await the actual condition.

### Scaffolding

Each side once carried a throwaway toolchain canary to prove its runner worked.
Both are now retired, the first real module having long since arrived. **Do not add
another** — the three laws apply without exception from here, and "What not to
test" below already excludes framework wiring.

## Tooling — `pc/` (Node + TypeScript)

- **Node ≥22.19** (22.23.2 present), npm, ESM, `"type": "module"`.
- **No build step.** TypeScript runs through Node's native type stripping;
  specifiers are `.ts` (`allowImportingTsExtensions`).
- **No test framework.** `node:test` + `node:assert/strict` only.
- **`erasableSyntaxOnly` is load-bearing, not decorative.** Non-erasable syntax
  (`enum`, `namespace`, parameter properties) is rejected at runtime with
  `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX: … not supported in strip-only mode`, so without
  the flag it would pass `npm test` and explode on a machine running plain `node`.
  `npm run typecheck` catches it statically. Verified by injection, 2026-09-30.
- **`npm test` does not run `typecheck`.** They are separate gates; run both.

```
cd pc
npm test                        # whole suite (glob: src/**/*.test.ts, test/**/*.test.ts)
node --test src/foo.test.ts     # one file
npm run typecheck               # tsc --noEmit
```

Dev deps only (`typescript`, `@types/node`). Zero runtime deps so far.

## Tooling — `app/` (Flutter + Dart)

- **Flutter 3.47.5 stable / Dart 3.13.4** at `~/develop/flutter`. `ANDROID_HOME=~/Android/Sdk`.
- **JDK:** Android Studio's bundled JBR (`/opt/android-studio/jbr`). No system JDK is
  installed; Gradle 9.3.1 accepts it. Java 25 emits a benign "restricted method"
  warning — not an error.
- **AVD:** `pi-droid` (API 36, x86_64, host GPU).
- Android targets come from Flutter: compileSdk/targetSdk **36**, minSdk **24**.
- **Pure logic must not import Flutter**, so it tests without a widget binding and
  stays fast.

```
cd app
flutter test                              # whole suite
flutter test test/foo_test.dart           # one file (scope each red/green witness to one file)
flutter analyze                           # must be clean
flutter run --profile -d <serial>         # boot the AVD first; discover the serial, never assume 5554
```

Dependencies: `flutter` only so far. Add one when a test demands it, not before.

### Goldens

Not in use yet. When introduced, two facts already established — both bit us once:

- Golden keys resolve **relative to the test file's directory**, not the package
  root. The first test placed in a nested directory silently changes the base.
- Failure artifacts are written to a `failures/` directory **beside the test file**
  and are not covered by the generated `app/.gitignore`. The root `.gitignore`
  already ignores `**/test/**/failures/`.

Goldens are a local regression net, not a portable oracle: they are renderer- and
font-dependent by construction. A golden failure means "look at the diff".

## Test layout

- **`pc/`** — colocated: `src/foo.ts` → `src/foo.test.ts`. Integration tests in
  `test/integration/*.test.ts`.
- **`app/`** — **`test/` mirroring `lib/`** (`lib/foo.dart` → `test/foo_test.dart`).
  Deliberately *not* colocated: `flutter test` discovers `test/` by default and `lib/`
  is the shipped tree. This is an explicit, permanent exception to the colocation
  rule above — not an oversight to be "fixed".

## What to test

- **Pure logic** — protocol encode/decode, session registry, event→message mapping,
  routing decisions. Unit tests, no I/O.
- **Boundaries** — spawned pi process, WebSocket, unix socket, filesystem.
  Integration tests using *real* local processes and temp dirs, not mocks.
- Prefer fakes over mocks. Mock only what cannot be run locally (third-party
  network).

## What not to test

- Trivial getters/setters, generated code, framework wiring.
- Coverage numbers. Test behavior, not lines.

## Definition of done

- New behavior was tested first and passes.
- Both suites green: `cd pc && npm test`, `cd app && flutter test`.
- Both static gates clean: `cd pc && npm run typecheck`, `cd app && flutter analyze`.
- No skipped or `.only` tests left behind.
- If a boundary genuinely cannot be tested yet, say so explicitly rather than
  silently skipping it.

## Where open work lives

Split by *kind*, not by size:

- **Actionable work → [GitHub issues](https://github.com/Tako88/PI-Droid/issues).**
  Bugs and gaps are issues. When a commit resolves one, put `Fixes #12` in the message
  so GitHub closes it — that is the whole point of it being an issue rather than a
  README bullet, which rots silently.
- **Deliberate limits → [`docs/known-limits.md`](docs/known-limits.md).** Things we
  have decided *not* to do, each with its reason. Do **not** file these as issues: a
  limitation is not a work item, and filing it makes the open-issue count lie about
  the project's state.

Both are versioned with the code, so a change that removes a constraint updates the
file in the same commit. `gh` is installed and authenticated; `gh issue create`,
`gh issue list` and `gh issue view` all work.

Write issue bodies for a human skimming: what is wrong in plain words first, then
`**To fix:**` and `**Where:**` (file paths). No internal jargon in the opening
sentence, and no assumption that the reader has already read the README.

## Commits

- Imperative subject, no trailing period. Aim for ≤50 chars: what changed, at a glance.
- Slight overruns are fine when the extra words carry something worth conveying. The
  limit is a readability target, not a gate.
- Body only when the *why* isn't obvious from the subject: ≤3 short lines. Don't
  restate the diff, don't narrate the process.
- No type prefixes (`feat:`, `fix:`) unless asked.
- Never merge or push without an explicit go-ahead.

## Branches and releases

- **`develop` is the integration branch and the GitHub default.** Features land
  here. Because it is the default, `Fixes #N` closes when the commit lands, and a
  pull request already targets the right branch.
- **`main` is the last released state**, always an ancestor of `develop`.
- **`main` moves only when there is something to release.** Docs, chores and other
  internal changes queue on `develop` and ride along with the next release — a commit
  being merged is not by itself a reason to cut a version.
- **A release fast-forwards `main` to `develop`'s tip and tags it `vX.Y.Z`.** One
  semver is shared by `app/pubspec.yaml` and `pc/package.json` (`PROTOCOL_VERSION`
  stays a separate integer, bumped only when the wire breaks), and the release is
  recorded in `CHANGELOG.md`.
- **Hotfixes cherry-pick onto `develop`.** Never merge `main` back into `develop`:
  the merge commit would break the linear, fast-forward-only history.

## Status

The hub, the bridge running inside a real pi, and the Android client are all built,
and the whole path has been exercised end to end on a phone. What is missing is in the
issue list; what is deliberately absent is in
[`docs/known-limits.md`](docs/known-limits.md).

Setup and architecture live in [`README.md`](README.md).
