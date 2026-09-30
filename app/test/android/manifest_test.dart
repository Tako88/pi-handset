// The app's whole job is to open a WebSocket to the hub. `INTERNET` is declared
// in the debug and profile manifests (Flutter's template puts it there for the
// tooling), but those are merged only into their own build types — a release
// build would ship with no network permission at all. No host test can catch
// that, so pin the one property that has no other gate: the permission must be
// declared in the MAIN manifest.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main manifest declares the INTERNET permission', () {
    // `flutter test` runs with cwd at the package root (`app/`).
    final manifest = File('android/app/src/main/AndroidManifest.xml');

    expect(
      manifest.existsSync(),
      isTrue,
      reason: 'expected android/app/src/main/AndroidManifest.xml relative to '
          '${Directory.current.path}',
    );

    final xml = manifest.readAsStringSync();
    expect(
      RegExp(
        r'<uses-permission\s+android:name="android\.permission\.INTERNET"\s*/>',
      ).hasMatch(xml),
      isTrue,
      reason: 'release builds merge only the main manifest; without INTERNET '
          'here a shipped app cannot open its hub WebSocket',
    );
  });
}
