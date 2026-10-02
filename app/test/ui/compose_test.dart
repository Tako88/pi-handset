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
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    String? sent;
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: (text) async {
          sent = text;
          return const CommandResult(ok: true);
        },
        onAbort: () {},
        onFollowUp: ok,
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'hello pi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();

    expect(sent, 'hello pi');
    expect(find.text('hello pi'), findsNothing);
  });

  testWidgets('long-pressing send runs the message after this turn',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    String? sent;
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: (text) async {
          sent = 'prompt:$text';
          return const CommandResult(ok: true);
        },
        onAbort: () {},
        onFollowUp: (text) async {
          sent = 'followup:$text';
          return const CommandResult(ok: true);
        },
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'after this');
    await tester.longPress(find.byKey(const Key('compose-send')));
    await tester.pump();

    // A long press must not also fire the tap: the two gestures send different
    // commands, and a follow-up that arrived as a steer would redirect the turn
    // it was meant to follow.
    expect(sent, 'followup:after this');
  });

  testWidgets('a follow-up confirms the send, not the timing', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: ok,
        onAbort: () {},
        onFollowUp: ok,
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'after this');
    await tester.longPress(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    // The app knows it sent a `followup`; whether pi queues it or runs it now is
    // pi's call — an idle agent ignores the mode entirely. So the notice claims
    // the send, never when it will land.
    expect(find.text('Sent as a follow-up'), findsOneWidget);
  });

  testWidgets('a refused follow-up reports the error, not a confirmation',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: ok,
        onAbort: () {},
        onFollowUp: (_) async =>
            const CommandResult(ok: false, error: 'the hub said no'),
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'after this');
    await tester.longPress(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    // A failed send must never be confirmed: the error check has to precede the
    // follow-up notice, or a refusal reads as delivered.
    expect(find.text('the hub said no'), findsOneWidget);
    expect(find.text('Sent as a follow-up'), findsNothing);
  });

  testWidgets('a disabled bar ignores the long press too', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var followUps = 0;
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        enabled: false,
        onSend: ok,
        onAbort: () {},
        onFollowUp: (text) async {
          followUps += 1;
          return const CommandResult(ok: true);
        },
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'after this');
    await tester.longPress(find.byKey(const Key('compose-send')));
    await tester.pump();

    expect(followUps, 0);
  });

  testWidgets('the compose field asks the keyboard for a newline, not a send',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: ok,
        onAbort: () {},
        onFollowUp: ok,
      )),
    );

    final field =
        tester.widget<TextField>(find.byKey(const Key('compose-field')));
    expect(field.textInputAction, TextInputAction.newline);
  });

  testWidgets('compose does not send an empty prompt', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var calls = 0;
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: (text) async {
          calls++;
          return const CommandResult(ok: true);
        },
        onAbort: () {},
        onFollowUp: ok,
      )),
    );

    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();

    expect(calls, 0);
  });

  testWidgets('a failed send surfaces its error', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: (_) async =>
            const CommandResult(ok: false, error: 'not connected'),
        onAbort: () {},
        onFollowUp: ok,
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'hi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('not connected'), findsOneWidget);
  });

  testWidgets('a successful send shows no error', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: ok,
        onAbort: () {},
        onFollowUp: ok,
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'hi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
      'a queued send tells the user the send was queued for the running turn',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: (_) async => const CommandResult(ok: true, queued: true),
        onAbort: () {},
        onFollowUp: ok,
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'hi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Queued for the running turn'), findsOneWidget);
  });

  testWidgets('a send the bridge did not queue shows no notice',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: (_) async => const CommandResult(ok: true, queued: null),
        onAbort: () {},
        onFollowUp: ok,
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'hi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a refused send shows its error, not a queued notice',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: (_) async => const CommandResult(
          ok: false,
          error: 'not connected',
          queued: true,
        ),
        onAbort: () {},
        onFollowUp: ok,
      )),
    );

    await tester.enterText(find.byKey(const Key('compose-field')), 'hi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('not connected'), findsOneWidget);
    expect(find.text('Queued for the running turn'), findsNothing);
  });

  testWidgets('abort invokes the abort callback', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var aborted = false;
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: ok,
        onAbort: () => aborted = true,
        onFollowUp: ok,
      )),
    );

    await tester.tap(find.byKey(const Key('compose-abort')));
    await tester.pump();

    expect(aborted, isTrue);
  });
}
