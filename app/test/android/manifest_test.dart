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

  test('main manifest declares the notification permissions', () {
    final xml = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    for (final permission in const [
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
    ]) {
      expect(
        RegExp(
          '<uses-permission\\s+android:name="${RegExp.escape(permission)}"\\s*/>',
        ).hasMatch(xml),
        isTrue,
        reason: '$permission must be in the main manifest',
      );
    }
  });

  test('main manifest declares no media or camera permission', () {
    // Sending one gallery image needs no runtime permission: the picker uses
    // the system photo picker / document UI, which grants per-item access. Pin
    // that no broad media or camera permission is declared, because the other
    // manifest tests assert presence only and so cannot catch an added one.
    final xml = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    for (final permission in const [
      'android.permission.READ_MEDIA_IMAGES',
      'android.permission.READ_EXTERNAL_STORAGE',
      'android.permission.WRITE_EXTERNAL_STORAGE',
      'android.permission.CAMERA',
    ]) {
      expect(
        RegExp(
          '<uses-permission\\s+android:name="${RegExp.escape(permission)}"',
        ).hasMatch(xml),
        isFalse,
        reason: '$permission must not be declared: the gallery picker needs no '
            'broad media or camera permission',
      );
    }
  });

  test('main manifest opts into predictive back', () {
    final xml = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      RegExp(
        r'<application\s+[^>]*android:enableOnBackInvokedCallback="true"',
        dotAll: true,
      ).hasMatch(xml),
      isTrue,
      reason: 'without the OS opt-in Android never delivers startBackGesture/'
          'commitBackGesture, so the transcript route cannot preview the list',
    );
  });

  test('main manifest declares the specialUse foreground service', () {
    final xml = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    // The service must be non-exported, typed `specialUse` (so it is not
    // subject to the dataSync cap), and torn down with the task so a stale
    // persistent notification cannot linger.
    expect(
      RegExp(
        r'<service\s+[^>]*android:name="\.HubConnectionService"[^>]*>',
        dotAll: true,
      ).hasMatch(xml),
      isTrue,
      reason: 'the service must be declared in the main manifest',
    );
    expect(
      RegExp(
        r'<service\s+[^>]*android:name="\.HubConnectionService"[^>]*android:foregroundServiceType="specialUse"[^>]*android:stopWithTask="true"',
        dotAll: true,
      ).hasMatch(xml),
      isTrue,
      reason: 'the service must be specialUse and stopWithTask',
    );
    expect(
      RegExp(
        r'<property\s+android:name="android\.app\.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"\s+android:value="[^"]+"\s*/>',
        dotAll: true,
      ).hasMatch(xml),
      isTrue,
      reason: 'a specialUse service needs its subtype property',
    );
  });
}
