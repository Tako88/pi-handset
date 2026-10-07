// The Gradle namespace and applicationId are the two identifiers that tie a
// build to the project: the namespace resolves the manifest's relative names
// (`android:name=".MainActivity"`) and the applicationId is what Android uses
// to identify the install. The id must be the app's own, not a vendor domain
// the project does not own.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Gradle namespace and application id are the app\'s own', () {
    // `flutter test` runs with cwd at the package root (`app/`).
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    for (final key in const ['namespace', 'applicationId']) {
      expect(
        RegExp('\\b$key\\s*=\\s*"io\\.github\\.tako88\\.pihandset"')
            .hasMatch(gradle),
        isTrue,
        reason: '$key must be io.github.tako88.pihandset, not a vendor domain',
      );
    }
  });

  test('every Kotlin source declares the Gradle namespace\'s package', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final declared = RegExp(r'namespace\s*=\s*"([^"]+)"').firstMatch(gradle);
    expect(
      declared,
      isNotNull,
      reason: 'android/app/build.gradle.kts declares no namespace',
    );
    final namespace = declared!.group(1)!;

    final sources = Directory('android/app/src/main/kotlin')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.kt'))
        .toList();
    expect(sources, isNotEmpty, reason: 'no Kotlin sources were found to check');

    for (final file in sources) {
      expect(
        file.readAsStringSync(),
        contains('package $namespace'),
        reason: '${file.path} must declare package $namespace to match the '
            'Gradle namespace',
      );
    }
  });
}
