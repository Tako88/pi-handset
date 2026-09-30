// Probes a mechanism the attach-protocol plan depends on: can the `app/` suite read a
// file that sits *above* the package root, or does `flutter test` resolve paths against
// the package root only?
//
// The plan needs this because shared protocol fixtures live at the repo root in
// `protocol/`, and both suites must assert the same bytes. Reading `../README.md`
// here answers the question before the plan is finalized rather than deferring it to
// execution time.
//
// This stays as a real test: step 13 of the plan depends on the same capability.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the suite can read a file above the package root', () {
    final file = File('../README.md');

    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected ../README.md relative to ${Directory.current.path}',
    );
    expect(file.readAsStringSync(), contains('pi-droid'));
  });
}
