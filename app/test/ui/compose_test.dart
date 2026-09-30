// Compose: a text field that sends `prompt` to the open session, plus a way to
// abort. A refused, unconnected or timed-out send must reach the screen — the
// prompt looks sent otherwise and is gone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/ui/compose_bar.dart';

Widget wrap(ComposeBar bar) => MaterialApp(home: Scaffold(body: bar));

Future<CommandResult> ok(String _) async => const CommandResult(ok: true);

void main() {
  testWidgets('compose sends the typed prompt', (tester) async {
    String? sent;
    await tester.pumpWidget(
      wrap(ComposeBar(onSend: (text) async {
        sent = text;
        return const CommandResult(ok: true);
      }, onAbort: () {})),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'hello pi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();

    expect(sent, 'hello pi');
    expect(find.text('hello pi'), findsNothing);
  });

  testWidgets('compose does not send an empty prompt', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      wrap(ComposeBar(onSend: (text) async {
        calls++;
        return const CommandResult(ok: true);
      }, onAbort: () {})),
    );

    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();

    expect(calls, 0);
  });

  testWidgets('a failed send surfaces its error', (tester) async {
    await tester.pumpWidget(
      wrap(ComposeBar(
        onSend: (_) async =>
            const CommandResult(ok: false, error: 'not connected'),
        onAbort: () {},
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'hi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('not connected'), findsOneWidget);
  });

  testWidgets('a successful send shows no error', (tester) async {
    await tester.pumpWidget(
      wrap(ComposeBar(onSend: ok, onAbort: () {})),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'hi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('abort invokes the abort callback', (tester) async {
    var aborted = false;
    await tester.pumpWidget(
      wrap(ComposeBar(onSend: ok, onAbort: () => aborted = true)),
    );

    await tester.tap(find.byKey(const Key('compose-abort')));
    await tester.pump();

    expect(aborted, isTrue);
  });
}
