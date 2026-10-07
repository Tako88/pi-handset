// The transcript app bar: context usage, the no-reading case, long and short
// names, 2x text scale and compaction.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/endpoint_store.dart';

import 'support/app_shell_harness.dart';

void main() {
  testWidgets('the transcript app bar shows the context usage', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);

    expect(find.text('23k / 128k · 18%'), findsOneWidget);
  });

  testWidgets('an unknown token count renders as a question mark', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrame(null, 128000));
    await settle(tester, h.scheduler);

    expect(find.text('? / 128k'), findsOneWidget);
  });

  testWidgets('no usage reading renders no label at all', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    expect(find.byKey(const Key('context-usage')), findsNothing);
  });

  testWidgets('a long session name gives way to the context label', (
    tester,
  ) async {
    final longName = 'a session title that goes on and on ' * 10;
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(
      sessionsFrame([
        {'sessionId': 's1', 'label': longName, 'agentState': 'idle'},
      ]),
    );
    await settle(tester, h.scheduler);
    await tester.tap(find.textContaining('a session title'));
    await settle(tester, h.scheduler);

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);

    final name = tester.renderObject<RenderParagraph>(
      find.byKey(const Key('session-name')),
    );
    final label = tester.renderObject<RenderParagraph>(
      find.byKey(const Key('context-usage')),
    );
    // The reading is what must survive: the name is the one that gets cut.
    expect(name.didExceedMaxLines, isTrue, reason: 'the name must be the one cut');
    expect(
      label.size.width,
      closeTo(label.getMaxIntrinsicWidth(double.infinity), 1.0),
      reason: 'the context label must render at its full width',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short session name is not cut, so the test above can fail', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);

    final name = tester.renderObject<RenderParagraph>(
      find.byKey(const Key('session-name')),
    );
    expect(name.didExceedMaxLines, isFalse);
  });

  testWidgets('a large text scale does not overflow the app bar', (
    tester,
  ) async {
    // A phone-sized viewport, not the 800px default: at 360dp the title slot is
    // genuinely too narrow for a large-text reading, which is the case this test
    // exists for.
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final longName = 'a session title that goes on and on ' * 10;
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: h.app(),
      ),
    );
    await pumpBootstrap(tester);
    h.factory.last.receive(
      sessionsFrame([
        {'sessionId': 's1', 'label': longName, 'agentState': 'idle'},
      ]),
    );
    await settle(tester, h.scheduler);
    await tester.tap(find.textContaining('a session title'));
    await settle(tester, h.scheduler);

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);

    // At three times the text size the reading is wider than the title slot. The
    // reading must still be whole — but the row must not overflow either, which
    // is the failure a plain `Row` would produce.
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('context-usage')), findsOneWidget);
    // The action sits in the same bar and must not push it into overflow either.
    expect(find.byKey(const Key('session-menu')), findsOneWidget);
  });

  testWidgets('a compaction shows in the app bar in place of the reading', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);
    expect(find.byKey(const Key('context-usage')), findsOneWidget);

    h.factory.last.receive(compactingFrame(true));
    await settle(tester, h.scheduler);

    // What the user sees: the app bar says what is happening, in the slot the
    // reading occupied — the number is what the compaction is about to change.
    expect(tester.widget<Text>(find.byKey(const Key('compacting'))).data, 'Compacting…');
    expect(find.byKey(const Key('context-usage')), findsNothing);
  });

  testWidgets('the reading returns when the compaction ends', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);
    h.factory.last.receive(compactingFrame(true));
    await settle(tester, h.scheduler);
    h.factory.last.receive(compactingFrame(false));
    await settle(tester, h.scheduler);

    // The indicator is transient state: it must clear itself, or the app bar
    // would claim a compaction is running forever.
    expect(find.byKey(const Key('compacting')), findsNothing);
    expect(find.byKey(const Key('context-usage')), findsOneWidget);
  });

  testWidgets('a compaction shows even with no reading yet', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    // No usage frame has arrived, so the slot is empty. The announcement must
    // still be visible — an auto-compaction can be the first thing that happens.
    expect(find.byKey(const Key('context-usage')), findsNothing);
    h.factory.last.receive(compactingFrame(true));
    await settle(tester, h.scheduler);

    expect(tester.widget<Text>(find.byKey(const Key('compacting'))).data, 'Compacting…');
  });
}
