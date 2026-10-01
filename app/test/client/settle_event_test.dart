// The hub client's settles stream: an `agent-settled` broadcast arrives with
// no active session or subscription, and is surfaced for the app to notify on.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, Object?> settledFrame({
  String sessionId = 's1',
  String label = 'work',
  String text = 'Done.',
  bool truncated = false,
}) => {
  'protocolVersion': 1,
  'type': 'agent-settled',
  'sessionId': sessionId,
  'label': label,
  'text': text,
  'truncated': truncated,
};

void main() {
  late FakeSocketFactory factory;
  late FakeScheduler scheduler;
  late HubClient client;

  setUp(() async {
    factory = FakeSocketFactory();
    scheduler = FakeScheduler();
    client = HubClient(
      socketFactory: factory.call,
      scheduler: scheduler,
      tokenStore: InMemoryTokenStore(initial: testToken),
      rng: () => 0.5,
    );
    await client.start('127.0.0.1');
    await pumpEventQueue();
  });

  test('an agent-settled frame reaches the settles stream', () async {
    final events = <AgentSettledEvent>[];
    final subscription = client.settles.listen(events.add);

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': <Object?>[],
    });
    await pumpEventQueue();

    factory.last.receive(settledFrame());
    await pumpEventQueue();

    expect(events, hasLength(1));
    expect(events.single.sessionId, 's1');
    expect(events.single.label, 'work');
    expect(events.single.text, 'Done.');
    expect(events.single.truncated, isFalse);
    await subscription.cancel();
  });

  test('a malformed agent-settled frame is ignored', () async {
    final events = <AgentSettledEvent>[];
    final subscription = client.settles.listen(events.add);

    // An empty label fails `decode`, so the frame never reaches the stream.
    factory.last.receive(settledFrame(label: ''));
    await pumpEventQueue();

    expect(events, isEmpty);
    await subscription.cancel();
  });

  test('the settles stream closes when the client stops', () async {
    var done = false;
    final subscription = client.settles.listen((_) {}, onDone: () => done = true);

    await client.stop();
    await pumpEventQueue();

    expect(done, isTrue);
    await subscription.cancel();
  });
}
