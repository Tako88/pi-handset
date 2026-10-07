// Listing pi's models: the app asks with a `listModels` command and the models
// ride back on the existing `command-result` as an optional `models` field.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_client.dart';

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

  test('listModels sends a command named listModels for the session', () async {
    final future = client.listModels('s1');

    final frame = factory.last.lastSent;
    expect(frame['type'], 'command');
    expect(frame['name'], 'listModels');
    expect(frame['sessionId'], 's1');

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': frame['id'],
      'ok': true,
      'models': [
        {'provider': 'anthropic', 'id': 'claude-sonnet-4', 'name': 'Claude Sonnet 4'},
      ],
    });

    final result = await future;
    expect(result.ok, isTrue);
  });

  test('a command-result carries the models', () async {
    final future = client.listModels('s1');
    final id = factory.last.lastSent['id']! as String;

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': true,
      'models': [
        {
          'provider': 'anthropic',
          'id': 'claude-sonnet-4',
          'name': 'Claude Sonnet 4',
        },
        {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
      ],
    });

    final result = await future;
    expect(result.models, isNotNull);
    expect(result.models!.map((model) => model.name).toList(), [
      'Claude Sonnet 4',
      'GPT-5',
    ]);
    expect(result.models![0].provider, 'anthropic');
    expect(result.models![0].id, 'claude-sonnet-4');
  });

  test('a result without models yields null', () async {
    final future = client.listModels('s1');
    final id = factory.last.lastSent['id']! as String;

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': true,
    });

    final result = await future;
    expect(result.models, isNull);
  });
}
