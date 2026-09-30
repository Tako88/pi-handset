// Viewing one session at a time: switching sessions unsubscribes the previous
// one, so a hub that only ever adds subscribers cannot keep sending the old
// session's session-less events, which the client would attribute to the new
// one. Deliberately NOT solved by tagging relayed events with a sessionId —
// that is a protocol change for a UI that views one session at a time.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

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

  /// Replays the client's own subscribe/unsubscribe frames to decide whether a
  /// compliant hub would deliver [event] for [sessionId] to this client.
  void deliverFromHub(String sessionId, Map<String, Object?> event) {
    var subscribed = false;
    for (final frame in factory.last.sentFrames) {
      if (frame['type'] == 'subscribe' && frame['sessionId'] == sessionId) {
        subscribed = true;
      } else if (frame['type'] == 'unsubscribe' &&
          frame['sessionId'] == sessionId) {
        subscribed = false;
      }
    }
    if (subscribed) factory.last.receive(event);
  }

  test('opening a session requests its history after the subscribe', () {
    client.subscribe('s1');

    final types = factory.last.sentFrames
        .map((frame) => frame['type'])
        .where((type) => type == 'subscribe' || type == 'history-request')
        .toList();
    expect(types, ['subscribe', 'history-request']);
    expect(factory.last.lastSent['sessionId'], 's1');
  });

  test('switching sessions unsubscribes the previous one', () {
    client.subscribe('A');
    client.subscribe('B');

    final transitions = factory.last.sentFrames
        .where((f) => f['type'] == 'subscribe' || f['type'] == 'unsubscribe')
        .map((f) => '${f['type']}:${f['sessionId']}')
        .toList();
    expect(transitions, ['subscribe:A', 'unsubscribe:A', 'subscribe:B']);
  });

  test('a throwing send does not escape subscribe', () {
    factory.last.throwOnSend = true;
    expect(() => client.subscribe('s1'), returnsNormally);
  });

  test('an event from the session we left does not land in the new one', () async {
    client.subscribe('A');
    client.subscribe('B');

    deliverFromHub('A', {
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'stream', 'seq': 1, 'text': 'A text'},
    });
    await pumpEventQueue();

    expect(client.transcript('B')!.streamingText, isEmpty);
    expect(client.transcript('A')!.streamingText, isEmpty);
  });
}
