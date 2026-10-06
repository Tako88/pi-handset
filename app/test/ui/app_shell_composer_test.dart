// The composer: the keyboard, the slash overlay and attachments.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/attachment.dart';
import 'package:pi_droid/client/endpoint_store.dart';
import 'package:pi_droid/ui/transcript_view.dart';

import 'support/app_shell_harness.dart';

void main() {
  testWidgets('the keyboard does not cover the composer', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    // The keyboard, as the engine reports it: a bottom view inset. Scaffold's
    // resizeToAvoidBottomInset only promises to resize the BODY, so anything in
    // the bottomNavigationBar slot stays pinned under the keyboard. viewInsets
    // is in PHYSICAL pixels, hence the devicePixelRatio conversion.
    const keyboard = 300.0;
    final dpr = tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();

    final screen = tester.view.physicalSize.height / dpr;
    final compose = tester.getRect(find.byKey(const Key('compose-field')));
    expect(compose.bottom, lessThanOrEqualTo(screen - keyboard));
  });

  testWidgets('typing / lists the session\'s commands and tapping one sends it',
      (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    // Reply to the per-open listCommands fetch with one command.
    final listId = h.factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'command' && frame['name'] == 'listCommands',
    )['id'];
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': listId,
      'ok': true,
      'commands': [
        {'name': 'review', 'description': 'Review the working tree'},
      ],
    });
    await settle(tester, h.scheduler);

    // Nothing to suggest until the draft starts with a slash.
    expect(find.byKey(const Key('compose-suggestions')), findsNothing);

    await tester.enterText(find.byKey(const Key('compose-field')), '/');
    await tester.pump();

    expect(
      find.byKey(const Key('compose-suggestion-0-review')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('compose-suggestion-0-review')));
    await tester.pump();

    // Picking inserts; it must not also send. The field shows the inserted name
    // with a trailing space, and nothing has gone out yet.
    expect(
      tester.widget<TextField>(find.byKey(const Key('compose-field'))).controller!.text,
      '/review ',
    );
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'prompt'),
      isEmpty,
    );

    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();

    final command = h.factory.last.sentFrames.last;
    expect(command['type'], 'command');
    expect(command['name'], 'prompt');
    expect(command['args'], {'text': '/review'});
  });

  testWidgets('opening the / overlay refetches the session\'s commands',
      (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    // Reply to the per-open listCommands fetch with one command.
    final listId = h.factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'command' && frame['name'] == 'listCommands',
    )['id'];
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': listId,
      'ok': true,
      'commands': [
        {'name': 'review', 'description': 'Review the working tree'},
      ],
    });
    await settle(tester, h.scheduler);

    await tester.enterText(find.byKey(const Key('compose-field')), '/');
    await tester.pump();
    final listFrames = h.factory.last.sentFrames
        .where((f) => f['type'] == 'command' && f['name'] == 'listCommands')
        .toList();
    // The subscribe-time fetch plus the overlay-open refetch.
    expect(listFrames, hasLength(2));
    expect(
      find.byKey(const Key('compose-suggestion-0-review')),
      findsOneWidget,
    );

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': listFrames.last['id'],
      'ok': true,
      'commands': [
        {'name': 'deploy', 'description': 'Ship it'},
      ],
    });
    await settle(tester, h.scheduler);
    expect(
      find.byKey(const Key('compose-suggestion-0-deploy')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('compose-suggestion-0-review')), findsNothing);
  });

  testWidgets('the floating panel never overflows with the keyboard up at 2x',
      (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    // Copy the ambient MediaQuery rather than supplying a fresh one: a fresh
    // `MediaQueryData` zeroes `viewInsets`, and the keyboard assertion below
    // would then be vacuous.
    await tester.pumpWidget(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
          ),
          child: h.app(),
        ),
      ),
    );
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    final listId = h.factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'command' && frame['name'] == 'listCommands',
    )['id'];
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': listId,
      'ok': true,
      'commands': [
        for (var i = 0; i < 10; i++)
          {
            'name': 'command-$i',
            'description':
                'A long description that wraps at twice the text scale ' * 2,
          },
      ],
    });
    await settle(tester, h.scheduler);

    await tester.enterText(find.byKey(const Key('compose-field')), '/');
    await tester.pump();

    const keyboard = 300.0;
    final dpr = tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('compose-suggestions')), findsOneWidget);

    final panel = tester.getSize(find.byKey(const Key('compose-suggestions')));
    final transcript = tester.getSize(find.byType(TranscriptView));
    // The panel shrinks to the transcript area rather than a fixed 200dp, which
    // is what makes the floating construction overflow-proof.
    expect(panel.height, lessThanOrEqualTo(transcript.height));

    final send = tester.getRect(find.byKey(const Key('compose-send')));
    final screen = tester.view.physicalSize.height / dpr;
    expect(send.bottom, lessThanOrEqualTo(screen - keyboard));
  });

  testWidgets('a hub without attachments shows no attach button', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    // An old hub cannot carry the image, so the affordance is omitted rather
    // than offered and silently dropped.
    expect(find.byKey(const Key('compose-attach')), findsNothing);
  });

  testWidgets('the attach button appears with the attachments capability', (
    tester,
  ) async {
    await openAttachmentsSession(tester);
    expect(find.byKey(const Key('compose-attach')), findsOneWidget);
  });

  testWidgets('picking an image shows a removable thumbnail', (tester) async {
    await openAttachmentsSession(
      tester,
      pickImage: () async => PickedImage(onePixelPng, 'image/png'),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('compose-attachment')), findsOneWidget);
  });

  testWidgets('a captioned attachment rides the prompt args and clears', (
    tester,
  ) async {
    final h = await openAttachmentsSession(
      tester,
      pickImage: () async => PickedImage(onePixelPng, 'image/png'),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('compose-field')), 'hi pi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    final command = h.factory.last.sentFrames.lastWhere(
      (frame) => frame['name'] == 'prompt',
    );
    expect(command['type'], 'command');
    expect(command['sessionId'], 's1');
    expect(command['args'], {
      'text': 'hi pi',
      'images': [
        {'data': base64Encode(onePixelPng), 'mimeType': 'image/png'},
      ],
    });
    // The image belongs to that one send; a leftover chip would silently ride
    // the next message too.
    expect(find.byKey(const Key('compose-attachment')), findsNothing);
  });

  testWidgets('an over-cap image is refused locally and nothing is sent', (
    tester,
  ) async {
    final h = await openAttachmentsSession(
      tester,
      pickImage: () async =>
          PickedImage(Uint8List(maxAttachmentBytes + 1), 'image/png'),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();

    expect(find.text('That image is too large to send'), findsOneWidget);
    expect(find.byKey(const Key('compose-attachment')), findsNothing);
    // The guard fires before any frame: an over-cap frame would be dropped by
    // the hub's maxPayload with no reply, which is the silent timeout.
    expect(
      h.factory.last.sentFrames.where(
        (frame) => frame['type'] == 'command' && frame['name'] == 'prompt',
      ),
      isEmpty,
    );
  });

  testWidgets('cancelling the picker leaves the composer untouched', (
    tester,
  ) async {
    final h = await openAttachmentsSession(tester, pickImage: () async => null);

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('compose-attachment')), findsNothing);
    expect(tester.takeException(), isNull);
    expect(
      h.factory.last.sentFrames.where((frame) => frame['name'] == 'prompt'),
      isEmpty,
    );
  });

  testWidgets('a picker error is shown, not mistaken for a cancel', (
    tester,
  ) async {
    await openAttachmentsSession(
      tester,
      pickImage: () async => throw StateError('gallery denied'),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not open the gallery'), findsOneWidget);
    expect(find.byKey(const Key('compose-attachment')), findsNothing);
  });

  testWidgets('a picked attachment does not leak into another session', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(
      h.app(pickImage: () async => PickedImage(onePixelPng, 'image/png')),
    );
    await pumpBootstrap(tester);
    h.factory.last.receive(attachmentsSessionsFrame([sessionS1, sessionS2]));
    await settle(tester, h.scheduler);

    await openSession(tester, h, 'api refactor');
    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('compose-attachment')), findsOneWidget);

    // Switch to the other session: the image belonged to s1 and must not follow.
    await pressSystemBack(tester, h.scheduler);
    await tester.pumpAndSettle();
    await openSession(tester, h, 'second session');
    expect(find.byKey(const Key('compose-attachment')), findsNothing);

    await tester.enterText(find.byKey(const Key('compose-field')), 'hi pi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();

    final command = h.factory.last.sentFrames.lastWhere(
      (frame) => frame['name'] == 'prompt',
    );
    expect(command['sessionId'], 's2');
    expect(command['args'], {'text': 'hi pi'});
  });

  testWidgets('a capability downgrade drops a stale pick', (tester) async {
    final h = await openAttachmentsSession(
      tester,
      pickImage: () async => PickedImage(onePixelPng, 'image/png'),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('compose-attachment')), findsOneWidget);

    // The hub downgrades in place (same session, no attachments capability).
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    expect(find.byKey(const Key('compose-attachment')), findsNothing);

    // Capability returns later: the old pick must not resurrect.
    h.factory.last.receive(attachmentsSessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    expect(find.byKey(const Key('compose-attachment')), findsNothing);
  });
}
