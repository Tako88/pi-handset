// Compose: a text field that sends `prompt` to the open session, plus a way to
// abort. A refused, unconnected or timed-out send must reach the screen — the
// prompt looks sent otherwise and is gone.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/attachment.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/ui/compose_bar.dart';
import 'package:pi_droid/ui/theme.dart';

Widget wrap(ComposeBar bar) => MaterialApp(theme: piTheme(Brightness.dark), home: Scaffold(body: bar));

/// The scaled variant applies the text scale *below* `MaterialApp`, so the
/// `MediaQuery` cannot be replaced by the one `MaterialApp` derives from the
/// view.
Widget wrapScaled(ComposeBar bar) => MaterialApp(
      theme: piTheme(Brightness.dark),
  home: Scaffold(
    body: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: bar,
    ),
  ),
);

/// A 1x1 PNG, enough for `Image.memory` to have real bytes to decode.
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<CommandResult> ok(String _) async => const CommandResult(ok: true);

/// The composer band's top and bottom rule colours, as painted.
({Color? top, Color? bottom}) bandRules(WidgetTester tester) {
  final box =
      tester
              .widget<Container>(
                find
                    .descendant(
                      of: find.byType(ComposeBar),
                      matching: find.byType(Container),
                    )
                    .first,
              )
              .decoration
          as BoxDecoration;
  final border = box.border! as Border;
  return (top: border.top.color, bottom: border.bottom.color);
}

void main() {
  testWidgets('the composer is ruled by the thinking level, like pi\'s editor', (
    tester,
  ) async {
    // pi colours its editor border with `getThinkingBorderColor(level)`
    // (interactive-mode.js:3635, falling back to `off`), so the composer band
    // carries the same ramp the thinking row and the level picker use.
    final roles = piTheme(Brightness.dark).extension<PiRoles>()!;
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    Future<void> pump(String? level) => tester.pumpWidget(
      wrap(
        ComposeBar(
          controller: controller,
          focusNode: focusNode,
          onSend: (text) => ok(text),
          onAbort: () {},
          onFollowUp: ok,
          thinkingLevel: level,
        ),
      ),
    );

    await pump('high');
    final high = bandRules(tester);
    expect(high.top, roles.thinkingHigh);
    expect(high.bottom, roles.thinkingHigh);

    await pump('max');
    expect(bandRules(tester).top, roles.thinkingMax);
    expect(
      bandRules(tester).top,
      isNot(high.top),
      reason: 'the band has to move when the level does',
    );

    // A fresh session has no level yet; pi falls back to `off`.
    await pump(null);
    expect(bandRules(tester).top, roles.thinkingOff);
  });
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

  testWidgets('no attach button without an onAttach handler', (tester) async {
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

    // An old hub advertises no attachments capability, so the shell passes no
    // handler. A button that did nothing would read as broken.
    expect(find.byKey(const Key('compose-attach')), findsNothing);
  });

  testWidgets('the attach button sits inside the field when supplied',
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
        onAttach: () {},
      )),
    );

    expect(
      find.descendant(
        of: find.byKey(const Key('compose-field')),
        matching: find.byKey(const Key('compose-attach')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping the attach button invokes onAttach', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var attached = 0;
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: ok,
        onAbort: () {},
        onFollowUp: ok,
        onAttach: () => attached++,
      )),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();

    expect(attached, 1);
  });

  testWidgets('a picked attachment shows a removable thumbnail',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var removed = 0;
    await tester.pumpWidget(
      wrap(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: ok,
        onAbort: () {},
        onFollowUp: ok,
        onAttach: () {},
        attachment: PickedImage(onePixelPng, 'image/png'),
        onRemoveAttachment: () => removed++,
      )),
    );

    expect(find.byKey(const Key('compose-attachment')), findsOneWidget);
    await tester.tap(find.byKey(const Key('compose-attachment-remove')));
    await tester.pump();
    expect(removed, 1);
  });

  testWidgets('an attachment chip does not overflow at double text scale',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      wrapScaled(ComposeBar(
        controller: controller,
        focusNode: focusNode,
        onSend: ok,
        onAbort: () {},
        onFollowUp: ok,
        onAttach: () {},
        attachment: PickedImage(onePixelPng, 'image/png'),
        onRemoveAttachment: () {},
      )),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('compose-attachment')), findsOneWidget);
  });

  testWidgets('a send with an image but no caption says so', (tester) async {
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
        onAttach: () {},
        attachment: PickedImage(onePixelPng, 'image/png'),
        onRemoveAttachment: () {},
      )),
    );

    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    // A silent dead tap is the failure: the chip stays and nothing is sent, so
    // the user cannot tell why.
    expect(find.text('Add a caption to send the image'), findsOneWidget);
    expect(calls, 0);
  });
}
