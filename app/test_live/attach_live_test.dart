// M10c — the live-provider attach run: the production client against a real
// hub, a real pi, and a *real* model.
//
// Every event shape M9/M10b ever saw came from `fauxAssistantMessage`, which
// streams a clean text_start/text_delta/text_end and nothing else. A thinking
// model also emits thinking_start/thinking_delta/thinking_end, which now stream
// through the SAME channel as the reply, tagged with `phase: 'thinking'`. This
// test is that path with no script: it drives the model from the same real
// `HubClient`, then asserts the reply arrived (and only the reply streamed as
// reply text), that `message` preceded the settled state, that the command
// result was successful, and that no unexpected payload kind — a stray error
// `status`, a duplicate message — reached the client. A scripted stream cannot
// catch any of those.
//
// COST: this drives a paid provider and is deliberately NOT under `test/`, so
// plain `flutter test` never runs or bills it. Run it explicitly:
//
//   ~/develop/flutter/bin/flutter test test_live/attach_live_test.dart
//
// Override the model with PI_DROID_LIVE_MODEL=provider/model.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_client.dart';
import 'package:pi_handset/client/hub_socket.dart';
import 'package:pi_handset/client/scheduler.dart';
import 'package:pi_handset/protocol/ticket.dart';

import '../test/client/support/fakes.dart';
import '../test/integration/support/attach_harness.dart';

/// Kept in one place so a different thinking model can be substituted with an
/// env var rather than editing this test.
const String defaultLiveModel = 'opencode-go/deepseek-v4.1-flash';

/// The exact token the model is told to emit. The assertion is equality, not
/// `contains` — see below: this model really does emit thinking frames, so if
/// they ever leaked into a `stream` payload the accumulated text would carry
/// reasoning *before* the reply and containment would still pass.
const String expectedReply = 'LIVE_OK';

/// A real model is slower to first token than any local fake. Bounded, never
/// unbounded.
const Duration livePromptTimeout = Duration(seconds: 120);

/// The payload kinds this run is allowed to produce. Streamed reasoning is a
/// `stream` frame carrying `phase: 'thinking'`, so it is in this set by kind;
/// `status`/`tool` are unexpected for a one-line answer. Anything outside this
/// set is a defect this test exists to surface.
const Set<String> expectedKinds = {'stream', 'message', 'agent'};

void main() {
  test('the production client drives a live thinking model end to end', () async {
    final modelSpec =
        Platform.environment['PI_DROID_LIVE_MODEL'] ?? defaultLiveModel;
    final slash = modelSpec.indexOf('/');
    expect(
      slash,
      greaterThan(0),
      reason: 'PI_DROID_LIVE_MODEL must be provider/model, got "$modelSpec"',
    );
    final provider = modelSpec.substring(0, slash);
    final model = modelSpec.substring(slash + 1);

    final tmp = Directory.systemTemp.createTempSync('pi-droid-live-');
    final runtimeDir = Directory('${tmp.path}/runtime')..createSync();
    final configDir = Directory('${tmp.path}/config')..createSync();
    final piCwd = Directory('${tmp.path}/cwd')..createSync();

    final children = <Child>[];
    HubClient? client;

    try {
      // Repo root: `flutter test` runs with cwd at the package root (`app/`).
      final appDir = Directory.current;
      expect(
        appDir.uri.pathSegments.where((segment) => segment.isNotEmpty).last,
        'app',
        reason:
            'this test expects to run from the app/ package root: ${appDir.path}',
      );
      final repoRoot = appDir.parent;
      final servePath = '${repoRoot.path}/pc/src/cli/serve.ts';
      final bridgePath = '${repoRoot.path}/pc/extensions/pi-droid-bridge.ts';
      for (final path in [servePath, bridgePath]) {
        expect(File(path).existsSync(), isTrue, reason: 'missing $path');
      }

      final environment = <String, String>{
        'XDG_RUNTIME_DIR': runtimeDir.path,
        'XDG_CONFIG_HOME': configDir.path,
        'PI_DROID_DEBUG': '1',
      };

      final viewerPort = await freePort();

      Future<Child> startHub() async {
        final hub = await spawn(
          'node',
          [servePath, '--port', '$viewerPort', '--no-lan'],
          workingDirectory: repoRoot.path,
          environment: environment,
          label: 'node serve',
        );
        children.add(hub);
        return hub;
      }

      // 1. A real supervisor on loopback.
      final hub = await startHub();
      await waitUntil(
        () => readDiscovery(runtimeDir.path)?['viewerPort'] == viewerPort,
        'the supervisor to publish its discovery record',
        timeout: bootTimeout,
        diagnostics: () => 'hub: ${hub.diagnostics()}',
      );

      // 2. A real pi with the bridge, *without* the faux harness, on the live
      //    provider. `-ne` drops discovery (no stray global extensions) while
      //    the explicit `-e` still loads the bridge.
      final piArgs = <String>[
        '--mode',
        'rpc',
        '-ne',
        '-e',
        bridgePath,
        '--provider',
        provider,
        '--model',
        model,
        // Force the model to reason. Under this test's minimal `-ne -nc`
        // context a 'flash' model may otherwise answer this one-liner without
        // emitting any thinking frames, leaving the bridge's ignore path
        // unexercised. `--thinking high` makes the request explicit; the
        // appended system instruction (internal reasoning, none in the answer)
        // makes the model actually produce thinking_start/delta/end.
        '--thinking',
        'high',
        '--append-system-prompt',
        'Always reason step by step internally before answering, even for '
            'simple requests. Never include your reasoning in the final answer.',
        '--no-session',
        '-nc',
      ];
      final pi = await spawn(
        'pi',
        piArgs,
        workingDirectory: piCwd.path,
        environment: environment,
        label: 'pi',
      );
      children.add(pi);

      // 3. Pair to the live hub and attach the production client.
      hub.process.kill(ProcessSignal.sigusr1);
      await waitUntil(
        () => pairingCodePattern.hasMatch(hub.stdout.toString()),
        'the supervisor to print a pairing code',
        timeout: bootTimeout,
        diagnostics: () => 'hub: ${hub.diagnostics()}',
      );
      final ticket = normalizeTicket(
        pairingCodePattern.firstMatch(hub.stdout.toString())!.group(1)!,
      );
      expect(ticket, isNotNull, reason: 'the printed code must be a valid ticket');

      final tokenStore = InMemoryTokenStore();
      final taps = <Tap>[];
      Future<HubSocket> socketFactory(Uri url) async {
        final inner = await dialHubSocket(url);
        final tap = Tap();
        taps.add(tap);
        return TapSocket(inner, tap);
      }

      client = HubClient(
        socketFactory: socketFactory,
        scheduler: TimerHubScheduler(),
        tokenStore: tokenStore,
      );
      await client
          .start('127.0.0.1', port: viewerPort, ticket: ticket!)
          .timeout(bootTimeout);
      await waitUntil(
        () => client!.state.status == HubConnectionStatus.connected,
        'the client to pair and authenticate',
        timeout: bootTimeout,
        diagnostics: () => clientDiagnostics(client!),
      );

      await waitUntil(
        () => client!.state.sessions.isNotEmpty,
        'pi to register its session with the hub',
        timeout: bootTimeout,
        diagnostics: () =>
            'hub: ${hub.diagnostics()}\npi: ${pi.diagnostics()}\n'
            '${clientDiagnostics(client!)}',
      );
      final sessionId = client.state.sessions.first.sessionId;
      client.subscribe(sessionId);

      // 4. Drive the live model. The prompt is tiny and expects an exact
      //    token; the appended system instruction (see piArgs) is what makes
      //    the model emit thinking frames for it.
      final result = await client
          .sendCommand(
            sessionId,
            'prompt',
            args: {'text': 'Reply with exactly: $expectedReply'},
          )
          .timeout(livePromptTimeout);
      expect(
        result.ok,
        isTrue,
        reason: 'the prompt must be accepted: ${result.error}',
      );
      await waitUntil(
        () => client!.transcript(sessionId)?.agentState == 'settled',
        'the live agent to settle',
        timeout: livePromptTimeout,
        diagnostics: () =>
            'pi: ${pi.diagnostics()}\n${clientDiagnostics(client!)}',
      );

      // 5. Assert on the frames the client consumed, never on the client's own
      //    buffer: the buffer clears on `message`/settle by design.
      final events = taps.expand((tap) => tap.eventPayloads()).toList();
      final kinds = events.map((payload) => payload['kind']).toSet();

      // 5a. The reply actually streamed and arrived, and *only* the reply.
      //
      // This model (`opencode-go/deepseek-v4.1-flash`) emits thinking frames
      // even for a one-line prompt: dumping the raw event stream for
      // `Reply with exactly: LIVE_OK` yields thinking_start / several
      // thinking_delta / thinking_end plus text_start / text_delta / text_end,
      // with a final text of `LIVE_OK`. Reasoning streams through the SAME
      // channel as the reply now, tagged with `phase: 'thinking'`, so the reply
      // is the phase-free half of it. Leaving the phase-bearing frames in would
      // concatenate the reasoning onto `LIVE_OK` — a corrupted transcript that
      // `contains` would wave through, which is why this is equality.
      final streamedText = events
          .where(
            (payload) =>
                payload['kind'] == 'stream' && payload['phase'] == null,
          )
          .map((payload) => payload['text']! as String)
          .join()
          .trim();
      expect(
        streamedText,
        equals(expectedReply),
        reason: 'only the reply may stream, got "$streamedText"',
      );

      final messages =
          events.where((payload) => payload['kind'] == 'message').toList();
      expect(
        messages,
        hasLength(1),
        reason:
            'exactly one assistant message must be relayed, got ${messages.length}; '
            'kinds=$kinds',
      );
      final delivered = messages.single['message']! as Map;
      expect(delivered['role'], 'assistant');
      expect(jsonEncode(delivered), contains(expectedReply));

      // 5b. `message` precedes `settled` — the app commits text on `message`
      //     and clears its buffer on settle, so the reverse order loses it.
      var messageIndex = -1;
      var settledIndex = -1;
      for (var index = 0; index < events.length; index++) {
        final payload = events[index];
        if (payload['kind'] == 'message') messageIndex = index;
        if (payload['kind'] == 'agent' && payload['state'] == 'settled') {
          settledIndex = index;
        }
      }
      expect(messageIndex, isNonNegative);
      expect(
        settledIndex,
        greaterThan(messageIndex),
        reason:
            'the message must arrive before settled, or the app commits the '
            'reply after clearing its buffer; events=${jsonEncode(events)}',
      );

      // 5c. No unexpected payload kind leaked. In particular a `thinking` frame
      //     must have been ignored, not mangled into another kind, and no error
      //     status may have arrived.
      expect(
        kinds.difference(expectedKinds),
        isEmpty,
        reason: 'unexpected payload kinds reached the client: $kinds',
      );
      expect(
        events
            .where((payload) =>
                payload['kind'] == 'status' && payload['event'] == 'error')
            .isEmpty,
        isTrue,
        reason: 'an error status reached the client: ${jsonEncode(events)}',
      );

      final transcript = client.transcript(sessionId)!;
      expect(transcript.agentState, 'settled');
      expect(transcript.streaming, isFalse);
    } finally {
      // Teardown on every path: close the client, kill each child by the pid we
      // spawned (never a `pkill` pattern), then remove the temp dirs.
      if (client != null) {
        try {
          await client.stop();
        } catch (_) {
          // Already gone.
        }
      }
      for (final child in children.reversed) {
        try {
          await child.kill(ProcessSignal.sigkill);
        } catch (_) {
          // Best effort.
        }
      }
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        // Best effort.
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
