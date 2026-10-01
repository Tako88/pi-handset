// The app root, driven with no network configured. A fresh install has neither
// a remembered endpoint nor a token, so it must render the pairing screen — and
// the toolchain canary it used to render must be gone.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/ui/app_shell.dart';
import 'package:pi_droid/ui/pairing_screen.dart';

import 'client/support/fakes.dart';

void main() {
  testWidgets('a fresh install renders pairing, not the canary', (tester) async {
    final store = InMemoryTokenStore();
    await tester.pumpWidget(
      PiDroidApp(
        client: HubClient(
          socketFactory: FakeSocketFactory().call,
          scheduler: FakeScheduler(),
          tokenStore: store,
        ),
        tokenStore: store,
        notifications: FakeNotificationPresenter(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PairingScreen), findsOneWidget);
    expect(find.text('42'), findsNothing);
  });
}
