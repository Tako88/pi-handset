// Step 2 of the app-scaffolding plan — the toolchain proof.
//
// This deliberately imports a module that does not exist yet. The failure it
// must produce is an unresolved import, which proves the runner, the package
// name and the resolution path all work, and that only the missing module is at
// fault. A different failure means the toolchain is wrong, not the code.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/toolchain_canary.dart';

void main() {
  test('the toolchain canary reports 42', () {
    expect(canaryAnswer(), 42);
  });
}
