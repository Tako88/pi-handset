// The session menu: compact, rename, thinking level, the model picker and the
// usage-driven menu values.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/endpoint_store.dart';

import 'support/app_shell_harness.dart';

void main() {
  testWidgets('choosing compact confirms before sending the command', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-compact')));
    await tester.pumpAndSettle();

    // The negative control: nothing is sent while the confirmation is up.
    expect(find.text('Compact session?'), findsOneWidget);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'compact'),
      isEmpty,
    );

    await tester.tap(find.byKey(const Key('compact-confirm-yes')));
    await settle(tester, h.scheduler);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'compact'),
      hasLength(1),
    );
  });

  testWidgets('cancelling compact sends nothing', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-compact')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('compact-confirm-no')));
    await settle(tester, h.scheduler);

    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'compact'),
      isEmpty,
    );
  });

  testWidgets('renaming sends the typed name', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename-field')), 'new name');
    await tester.pump();
    await tester.tap(find.byKey(const Key('rename-submit')));
    await settle(tester, h.scheduler);

    final frame = h.factory.last.sentFrames.last;
    expect(frame['name'], 'setSessionName');
    expect((frame['args']! as Map)['name'], 'new name');
  });

  testWidgets('choosing a thinking level sends it', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-thinking')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('thinking-low')));
    await settle(tester, h.scheduler);

    final frame = h.factory.last.sentFrames.last;
    expect(frame['name'], 'setThinkingLevel');
    expect((frame['args']! as Map)['level'], 'low');
  });

  testWidgets('the menu shows the level from a usage frame', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrameWithLevel(23400, 128000, 'high'));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('session-menu-thinking-level')))
          .data,
      'high',
    );
  });

  testWidgets('a later usage frame updates the level shown', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrameWithLevel(23400, 128000, 'high'));
    await settle(tester, h.scheduler);
    h.factory.last.receive(usageFrameWithLevel(23400, 128000, 'low'));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('session-menu-thinking-level')))
          .data,
      'low',
    );
  });

  testWidgets('choosing a model lists the models and sends the reference', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    final listFrame = await tapModelItem(tester, h);
    expect(listFrame['sessionId'], 's1');

    h.factory.last.receive(
      modelsReply(listFrame['id']! as String, [
        {
          'provider': 'anthropic',
          'id': 'claude-sonnet-4',
          'name': 'Claude Sonnet 4',
        },
        {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('model-picker')), findsOneWidget);
    await tester.tap(find.byKey(const Key('model-openai-gpt-5')));
    await settle(tester, h.scheduler);

    final frame = h.factory.last.sentFrames.last;
    expect(frame['name'], 'setModel');
    // The reference, not the display name: the bridge resolves it through the
    // registry.
    expect(frame['args'], {'provider': 'openai', 'id': 'gpt-5'});
  });

  testWidgets('a refused model switch shows the error, not silence', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    final listFrame = await tapModelItem(tester, h);
    h.factory.last.receive(
      modelsReply(listFrame['id']! as String, [
        {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model-openai-gpt-5')));
    await tester.pumpAndSettle();

    final setFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'setModel',
    );
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': setFrame['id'],
      'ok': false,
      'error': 'model not accepted',
    });
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(find.text('model not accepted'), findsOneWidget);
  });

  testWidgets('no models shows a message, not an empty sheet', (tester) async {
    final h = await openFirstSession(tester);

    final listFrame = await tapModelItem(tester, h);
    h.factory.last.receive(modelsReply(listFrame['id']! as String, []));
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(find.byKey(const Key('model-picker')), findsNothing);
    expect(find.text('No models available'), findsOneWidget);
  });

  testWidgets('a failed model list shows the error, not an empty sheet', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    final listFrame = await tapModelItem(tester, h);
    h.factory.last.receive(
      modelsReply(
        listFrame['id']! as String,
        [],
        ok: false,
        error: 'hub down',
      ),
    );
    await settle(tester, h.scheduler);
    await tester.pump();

    // The list failed: the cause must reach the screen, and no picker may open
    // on the stale/empty listing.
    expect(find.byKey(const Key('model-picker')), findsNothing);
    expect(find.text('hub down'), findsOneWidget);
  });

  testWidgets('dismissing the model picker sends nothing and stays silent', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    final listFrame = await tapModelItem(tester, h);
    h.factory.last.receive(
      modelsReply(listFrame['id']! as String, [
        {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('model-picker')), findsOneWidget);

    // The barrier outside the sheet: dismissing returns null, which must be a
    // silent no-op rather than a refusal or a phantom setModel. `pumpAndSettle`
    // (not `settle`) so the pop animation finishes and the sheet leaves the tree.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('model-picker')), findsNothing);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'setModel'),
      isEmpty,
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the menu shows the model from a usage frame', (tester) async {
    final h = await openFirstSession(tester);

    h.factory.last.receive(
      usageFrameWithModel(23400, 128000, 'anthropic', 'claude-sonnet-4', 'Claude Sonnet 4'),
    );
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('session-menu-model-name')))
          .data,
      'Claude Sonnet 4',
    );
  });

  testWidgets('the menu level follows the usage frame after a model switch', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    h.factory.last.receive(usageFrameWithLevel(23400, 128000, 'high'));
    await settle(tester, h.scheduler);

    final listFrame = await tapModelItem(tester, h);
    h.factory.last.receive(
      modelsReply(listFrame['id']! as String, [
        {
          'provider': 'anthropic',
          'id': 'claude-sonnet-4',
          'name': 'Claude Sonnet 4',
        },
        {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model-openai-gpt-5')));
    await tester.pumpAndSettle();
    final setFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'setModel',
    );
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': setFrame['id'],
      'ok': true,
    });
    await settle(tester, h.scheduler);

    // The switch cascades a clamping thinking-level change on pi's side, which
    // arrives as a fresh `usage` frame. The menu absorbs it rather than sticking
    // on the pre-switch level.
    h.factory.last.receive(usageFrameWithLevel(23400, 128000, 'low'));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('session-menu-thinking-level')))
          .data,
      'low',
    );
  });
}
