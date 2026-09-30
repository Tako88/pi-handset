// Step 4 of the app-scaffolding plan — the widget-level toolchain proof.
//
// At this point `main.dart` is still the `flutter create --empty` template, which
// renders 'Hello World!'. So this test must fail with *found 0 matching
// candidates* for '42' — that failure is the witness that the widget tester and
// its finders work, and that main.dart is the file under our control.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/main.dart';

void main() {
  testWidgets('the app root renders the canary value', (tester) async {
    await tester.pumpWidget(const MainApp());

    expect(find.text('42'), findsOneWidget);
  });
}
