# Development

Toolchain, tests and the deeper install notes. Orientation is in
[`../README.md`](../README.md).

## Running the tests

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
PI_HANDSET_LIVE_MODEL=provider/model flutter test test_live/attach_live_test.dart
```

It lives outside `test/` so `flutter test` never picks it up, and it is deliberately
not a `skip:` — a test that is skipped by default is the never-failing gate this
project rejects. Run it by hand when the provider integration matters.


## Local setup

This section describes the machine pi-handset is currently developed on. Paths are
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

The AVD predates the rename and was left alone — creating a new one to change its
name is not worth re-installing the system image, and nothing in the code names it.

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


## Installing the bridge into your pi

The hub and the app are useless without the **bridge**, and the bridge is a pi
extension: it only exists inside a running `pi`. `pc/` is a pi package, so install it
with pi's own package command:

```sh
pi install /path/to/pi-handset/pc
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
(containing `*.test.ts`) is what keeps `pi-handset-bridge.test.ts` from being loaded
as a live extension.

To confirm the bridge loaded without starting a hub, point the runtime dir at an
empty one and watch for its complaint:

```sh
XDG_RUNTIME_DIR=/tmp/empty PI_HANDSET_DEBUG=1 pi --mode rpc --no-session -nc
# pi-handset bridge: no hub discovered   <- loaded, and looking for a hub
```

The same flag on the **hub** carries a *spawned* session's bridge output — its stderr,
not the rpc event stream the same child prints on stdout — to the hub's stderr. Every child's pipes are drained, so without this a `socket closed (4002)` line
from a session the app started would reach nobody at all. A session you started
yourself is unaffected: that bridge writes to the terminal pi runs in.


## Running the hub

`pc/` is also the hub's CLI. Linking the package puts `pi-handset` on `PATH`:

```sh
cd pc
npm link          # once; `pi-handset` then resolves to this checkout
pi-handset pair   # mint a pairing code, print a QR
```

`npm run serve` and `npm run pair` do the same from `pc/` without linking.

### As a systemd user service

`pc/systemd/pi-handset.service` runs the hub in the background, started at login and
outliving the terminal that installed it. Link it rather than copy it, so the unit
stays the checked-in file:

```sh
systemctl --user link "$PWD/systemd/pi-handset.service"
systemctl --user enable --now pi-handset.service
journalctl --user -u pi-handset -f
```

Editing the unit takes effect after `systemctl --user daemon-reload` and
`systemctl --user restart pi-handset`. To change a flag — `--no-lan`, `--port`, a
different `--max-sessions` — edit `ExecStart` in the repo file and do those two
commands.

Three settings are load-bearing and should not be dropped:

- **`Environment=XDG_RUNTIME_DIR=/run/user/%U`** — the bridge finds the hub through
  the discovery record under that variable's directory. If the service inherited a
  different one, the hub would publish where no terminal-launched `pi` looks.
- **`RestartPreventExitStatus=1 2`** — `serve` exits 1 for a held lock, an existing
  hub or a taken port, and 2 for bad flags. Those are conflicts, not crashes:
  restarting cannot fix them, so the unit fails with the reason in the journal
  instead of hot-looping.
- **`ExecStart=%h/.local/bin/pi-handset`** — that is where `npm link` puts the bin.
  `PATH` is pinned in the unit as well because the shebang resolves `node` through
  `/usr/bin/env`, which does not see your shell's environment.

A hub started by hand is not a second hub — it exits 1 on the lock, which is why the
unit then reads `failed` rather than `active`. Stop the manual one first.

**`npm link`, not `npm install -g`.** Node refuses to strip types from any file
under a real `node_modules` (`ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`), so a
globally *installed* `.ts` bin is dead on arrival; the link is a symlink to the
checkout, so it is not. Publishing needs a build step first — issue #50.

## Release signing

Anything handed to someone else is signed with a real release key, never the
per-machine debug key. Two files, both outside version control:

- **`~/.android/keystores/pi-handset-release.jks`** — PKCS#12, RSA 4096,
  `CN=pi-handset`, valid until 2056, with its password file beside it. **Back both up.**
  Losing the key is permanent: Android only updates an installed app from a build
  signed with the same key, so losing it means every user uninstalls and re-pairs.
- **`app/android/key.properties`** — points at that keystore. Nothing to add to
  `.gitignore`: Flutter's generated `app/android/.gitignore` already covers
  `key.properties`, `**/*.jks` and `**/*.keystore`.

The certificate's SHA-256 fingerprint, for checking an artifact by hand — re-derive it
with `keytool -list -v -keystore ~/.android/keystores/pi-handset-release.jks`:

```
1B:2C:25:E1:A2:0C:0B:50:7D:5F:C3:37:05:BA:43:AC:E6:64:40:3D:2E:5B:75:B4:3A:0C:0E:6E:3F:99:9E:6A
```

A release build **refuses to run** while `key.properties` is missing. The alternative
— quietly falling back to the debug key — yields an APK that cannot update anything
built on another machine, and nothing about it looks wrong until a phone rejects the
update. `ALLOW_DEBUG_SIGNED_RELEASE=1 flutter build apk --release` builds one anyway,
deliberately.

Build the artifact a release carries, then prove which key signed it:

```sh
cd app
flutter build apk --release --split-per-abi --target-platform android-arm64
PATH=/opt/android-studio/jbr/bin:$PATH "$ANDROID_HOME/build-tools/36.0.0/apksigner" \
  verify --print-certs build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

`apksigner` is a shell wrapper that needs a `java` on `PATH`; the bundled JBR is
enough, as above. `--split-per-abi` writes one APK per ABI and the arm64 one — about
26 MB — covers every phone from roughly 2017 on. Watch the version code: Flutter adds
an ABI offset to `versionCode` (arm64 gets `+2000`), so ship the same ABI each time or
the ordering between builds stops meaning anything.

```sh
gh release create v0.2.0 --verify-tag --title "pi-handset v0.2.0" --notes-file NOTES \
  app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```


## The design record

`.pi/plans/` holds the plan, the adversarial review and the execution log — with the
red/green witnesses — for each feature. It is **gitignored**, so it is a local-only
archive; the conclusions that matter are written up in the docs beside it.
