// M10b — the app's *production* client against a real hub and a real pi.
//
// Every other app test drives `HubClient` through `FakeHubSocket`; this one
// wires the same client to a spawned `node pc/src/cli/serve.ts` and a spawned
// `pi` carrying the bridge and the M9 faux-provider harness. It is the app-side
// counterpart of `pc/test/integration/bridge-in-pi.test.ts`.
//
// What it proves end to end:
//
// 1. Pairing reaches a live hub: `SIGUSR1` makes `serve` print a code, and the
//    client exchanges it for the persistent token.
// 2. Attach and drive: the pi session registers, the client subscribes, a
//    `prompt` command streams from the faux provider to exactly the scripted
//    text, the final `message` payload precedes the terminal `settled` state
//    (the ordering the transcript commit depends on), and the command returns
//    a successful result.
// 3. The plan's acceptance case: the hub is restarted on the same port, the
//    client reconnects with the *stored token* (never the spent ticket) and
//    re-subscribes, and a second prompt streams.
//
// Repo-root resolution: Dart has no `__FILE__`. `flutter test` sets the cwd to
// the package root (`app/`), the mechanism `test/fixtures_reachable_test.dart`
// already depends on, so the repo root is that directory's parent.
//
// Token store: `InMemoryTokenStore` from `test/client/support/fakes.dart`.
// `flutter_secure_storage` needs platform channels and cannot run under
// `flutter test`, so the persisted token is in memory here — not the real
// store. The real store is exercised separately; this test exercises the
// *protocol* persistence (the token survives a reconnect, and the hub reads the
// same token file from `XDG_CONFIG_HOME`).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/hub_socket.dart';
import 'package:pi_droid/client/scheduler.dart';
import 'package:pi_droid/client/transcript.dart';
import 'package:pi_droid/protocol/ticket.dart';

import '../client/support/fakes.dart';
import 'support/attach_harness.dart';

/// The value the faux provider is scripted with; asserted byte-for-byte.
const String fauxText = 'M10B_FAUX_OK';

/// A local provider replies fast; the boot/reconnect bounds come from the
/// harness.
const Duration promptTimeout = Duration(seconds: 45);

void main() {
  test(
    'the production client pairs, drives a real pi, and survives a hub restart',
    () async {
      final tmp = Directory.systemTemp.createTempSync('pi-droid-attach-');
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
        final harnessPath =
            '${repoRoot.path}/pc/test/integration/support/faux-provider.ts';
        for (final path in [servePath, bridgePath, harnessPath]) {
          expect(File(path).existsSync(), isTrue, reason: 'missing $path');
        }

        // Same temp XDG dirs for the hub and pi: the token lives in
        // XDG_CONFIG_HOME, the discovery record in XDG_RUNTIME_DIR.
        final environment = <String, String>{
          'XDG_RUNTIME_DIR': runtimeDir.path,
          'XDG_CONFIG_HOME': configDir.path,
          'PI_DROID_FAUX_TEXT': fauxText,
          'PI_DROID_DEBUG': '1',
        };

        // `serve` rejects `--port 0`; pick a free port and use a stable one
        // across the restart so the client's saved URL stays valid.
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
        var hub = await startHub();
        await waitUntil(
          () => readDiscovery(runtimeDir.path)?['viewerPort'] == viewerPort,
          'the supervisor to publish its discovery record',
          timeout: bootTimeout,
          diagnostics: () => 'hub: ${hub.diagnostics()}',
        );
        expect(
          readDiscovery(runtimeDir.path)?['agentPort'],
          isA<int>(),
          reason: 'the discovery record must publish the bridge listener port',
        );

        // 2. A real pi with the bridge and the faux provider (M9's recipe).
        final pi = await spawn(
          'pi',
          [
            '--mode',
            'rpc',
            '-ne',
            '-e',
            harnessPath,
            '-e',
            bridgePath,
            '--provider',
            'faux',
            '--model',
            'faux-1',
            '--no-session',
            '-nc',
          ],
          workingDirectory: piCwd.path,
          environment: environment,
          label: 'pi',
        );
        children.add(pi);

        // 3. Pairing to a live hub: SIGUSR1 makes serve print a redeemable code.
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
        expect(
          ticket,
          isNotNull,
          reason: 'the printed code must be a valid pairing ticket',
        );

        // 4. The production client: dart:io socket, real timers. Only the token
        //    store is an in-memory double (platform channels are unavailable).
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
          diagnostics: () => _clientDiagnostics(client!),
        );
        expect(
          await tokenStore.read(),
          isNotNull,
          reason:
              'pairing must persist the token so a later run never re-pairs',
        );

        // 5. The bridge registers pi's session with the hub.
        await waitUntil(
          () => client!.state.sessions.isNotEmpty,
          'pi to register its session with the hub',
          timeout: bootTimeout,
          diagnostics: () =>
              'hub: ${hub.diagnostics()}\npi: ${pi.diagnostics()}\n'
              '${_clientDiagnostics(client!)}',
        );
        final sessionId = client.state.sessions.first.sessionId;
        expect(sessionId, isNotEmpty);

        client.subscribe(sessionId);

        // 6. Opening a session must request its history, not merely subscribe:
        //    without the request the backlog never arrives and the app shows
        //    "No messages yet." even though pi has a prior conversation.
        await waitUntil(
          () => taps
              .expand((tap) => tap.outboundOfType('history-request'))
              .isNotEmpty,
          'opening a session to request its history',
          timeout: bootTimeout,
          diagnostics: () =>
              'outbound=${taps.expand((tap) => tap.outbound).toList()}',
        );
        final openingTap = taps.firstWhere(
          (tap) => tap.outboundOfType('history-request').isNotEmpty,
        );
        expect(
          openingTap.outbound
              .where(
                (frame) =>
                    frame['type'] == 'subscribe' ||
                    frame['type'] == 'history-request',
              )
              .map((frame) => frame['type'])
              .take(2)
              .toList(),
          ['subscribe', 'history-request'],
          reason: 'the history-request must follow the subscribe',
        );
        await waitUntil(
          () => client!.transcript(sessionId)?.historyLoaded == true,
          'the opened session history to be acknowledged by a snapshot',
          timeout: bootTimeout,
          diagnostics: () =>
              'hub: ${hub.diagnostics()}\npi: ${pi.diagnostics()}\n'
              '${_clientDiagnostics(client!)}',
        );

        // 7. Drive one prompt end to end.
        final first = await client
            .sendCommand(sessionId, 'prompt', args: {'text': 'first prompt'})
            .timeout(promptTimeout);
        expect(
          first.ok,
          isTrue,
          reason: 'the prompt must be accepted: ${first.error}',
        );
        await waitUntil(
          () => client!.transcript(sessionId)?.agentState == 'settled',
          'the agent to settle after the first prompt',
          timeout: promptTimeout,
          diagnostics: () =>
              'pi: ${pi.diagnostics()}\n${_clientDiagnostics(client!)}',
        );

        // 8. The app-visible sequence, asserted on the frames the client
        //    consumed: stream* -> message -> settled.
        //
        //    The client's own streaming buffer is deliberately *not* asserted
        //    here: `_onEvent` clears it on `message`/settle, and the coalesced
        //    `changes` notification fires after the frame batch, so a fast
        //    local provider clears the buffer before any observer sees it.
        //    What the client accumulates is exactly these wire deltas (its
        //    buffer is their concatenation), and the committed transcript below
        //    is the app-visible result.
        final events = taps.expand((tap) => tap.eventPayloads()).toList();
        final streamedText = events
            .where((payload) => payload['kind'] == 'stream')
            .where((payload) => payload['text'] is String)
            .map((payload) => payload['text']! as String)
            .join();
        expect(
          streamedText,
          fauxText,
          reason:
              'the stream deltas must accumulate to exactly the faux text',
        );
        // Per-role, not a single total. M2 relays a THIRD role, `toolResult`;
        // this recipe runs no tools, so its count must be zero.
        final messageIndexes = <int>[];
        final messageRoles = <String>[];
        var settledIndex = -1;
        for (var index = 0; index < events.length; index++) {
          final payload = events[index];
          if (payload['kind'] == 'message') {
            messageIndexes.add(index);
            final message = (payload['message']! as Map).cast<String, Object?>();
            messageRoles.add(message['role']! as String);
          }
          if (payload['kind'] == 'agent' && payload['state'] == 'settled') {
            settledIndex = index;
          }
        }
        final userMessageIndexes = <int>[];
        final assistantMessageIndexes = <int>[];
        final toolResultIndexes = <int>[];
        for (var i = 0; i < messageRoles.length; i++) {
          if (messageRoles[i] == 'user') userMessageIndexes.add(messageIndexes[i]);
          if (messageRoles[i] == 'assistant') {
            assistantMessageIndexes.add(messageIndexes[i]);
          }
          if (messageRoles[i] == 'toolResult') {
            toolResultIndexes.add(messageIndexes[i]);
          }
        }
        expect(
          userMessageIndexes,
          hasLength(1),
          reason: 'exactly one user prompt must be relayed',
        );
        expect(
          assistantMessageIndexes,
          hasLength(1),
          reason: 'exactly one assistant reply must be relayed',
        );
        expect(
          toolResultIndexes,
          isEmpty,
          reason: 'the plain recipe runs no tools',
        );
        expect(
          messageIndexes,
          hasLength(2),
          reason: 'no role other than user and assistant may be relayed here',
        );
        expect(
          settledIndex,
          greaterThan(assistantMessageIndexes.single),
          reason:
              'the assistant message must arrive before the settled state, or '
              'the app commits the reply after it has cleared its buffer',
        );
        final delivered =
            events[assistantMessageIndexes.single]['message']! as Map;
        expect(delivered['role'], 'assistant');
        expect(jsonEncode(delivered), contains(fauxText));

        final transcript = client.transcript(sessionId)!;
        expect(transcript.agentState, 'settled');
        expect(transcript.streaming, isFalse);
        expect(transcript.streamingText, isEmpty);
        // A relayed `message` stores the bare message object; a `snapshot`
        // (history) stores `{type: 'message', message: {...}}` wrappers. Either
        // shape is a committed assistant reply.
        bool isAssistantReply(Object? entry) {
          if (entry is! Map) return false;
          final role = entry['message'] is Map
              ? (entry['message']! as Map)['role']
              : entry['role'];
          return role == 'assistant' && jsonEncode(entry).contains(fauxText);
        }

        expect(
          transcript.entries.any(isAssistantReply),
          isTrue,
          reason:
              'the committed transcript must contain the assistant reply: '
              '${_clientDiagnostics(client)}',
        );
        // M1 end to end: the derived blocks carry the user's own prompt and the
        // assistant reply, both committed from relayed `message` payloads.
        final committedBlocks = deriveBlocks(transcript.entries);
        expect(
          committedBlocks
              .where((block) => block.fromUser && block.kind == TranscriptBlockKind.text)
              .map((block) => block.text),
          contains('first prompt'),
          reason:
              'the user\'s own message must appear as a block: '
              '${committedBlocks.map((block) => block.text).toList()}',
        );
        expect(
          committedBlocks.any(
            (block) =>
                !block.fromUser &&
                block.kind == TranscriptBlockKind.text &&
                block.text.contains(fauxText),
          ),
          isTrue,
          reason: 'the assistant reply must appear as a block',
        );

        // 9. The plan's acceptance case: restart the hub on the same port with
        //    the same XDG dirs. The token file persists, so no re-pairing.
        final tapsBeforeRestart = taps.length;
        final deadPid = hub.pid;
        await hub.kill(ProcessSignal.sigterm);
        hub = await startHub();
        await waitUntil(
          () {
            final record = readDiscovery(runtimeDir.path);
            return record != null &&
                record['pid'] != deadPid &&
                record['viewerPort'] == viewerPort;
          },
          'the restarted supervisor to publish its discovery record',
          timeout: reconnectTimeout,
          diagnostics: () => 'hub: ${hub.diagnostics()}',
        );

        // Give the bridge time to re-read the discovery record and find the new
        // agent port; the client must redial the unchanged viewer port.
        await waitUntil(
          () => taps.length > tapsBeforeRestart,
          'the client to open a new connection after the restart',
          timeout: reconnectTimeout,
          diagnostics: () =>
              'taps=${taps.length}\n${_clientDiagnostics(client!)}',
        );
        // A restarted hub can refuse or drop the first redial, so the client
        // may dial more than once in this phase. Fold across every tap opened
        // after the restart rather than pinning the last one, which could be an
        // abandoned socket.
        List<Tap> reconnectedTaps() => taps.sublist(tapsBeforeRestart);
        await waitUntil(
          () => reconnectedTaps()
              .expand((tap) => tap.outboundOfType('hello'))
              .any((hello) => hello.containsKey('token')),
          'the client to reconnect with the persisted token',
          timeout: reconnectTimeout,
          diagnostics: () =>
              'taps=${taps.length}\noutbound='
              '${reconnectedTaps().expand((tap) => tap.outbound).toList()}',
        );
        expect(
          reconnectedTaps()
              .expand((tap) => tap.outboundOfType('hello'))
              .any((hello) => hello.containsKey('ticket')),
          isFalse,
          reason: 'a restart must not demand re-pairing',
        );
        await waitUntil(
          () => reconnectedTaps()
              .expand((tap) => tap.outboundOfType('subscribe'))
              .isNotEmpty,
          'the client to re-subscribe its active session',
          timeout: reconnectTimeout,
          diagnostics: () =>
              'taps=${taps.length}\noutbound='
              '${reconnectedTaps().expand((tap) => tap.outbound).toList()}',
        );

        // The subscription only holds once the bridge has re-registered; a
        // snapshot answering the re-requested history is the proof. Wait on a
        // *reconnected* tap's inbound snapshot: `historyLoaded` is already true
        // from the open-time snapshot, so it cannot prove this reconnect.
        await waitUntil(
          () => reconnectedTaps()
              .expand((tap) => tap.inbound)
              .any((frame) => frame['type'] == 'snapshot'),
          'the re-subscription to be acknowledged by a snapshot',
          timeout: reconnectTimeout,
          diagnostics: () =>
              'hub: ${hub.diagnostics()}\npi: ${pi.diagnostics()}\n'
              '${_clientDiagnostics(client!)}',
        );

        // A reconnect must not discard the transcript the user can already
        // see. The reply from step 6 was on screen before the restart; after
        // the client re-attaches it must still be there.
        expect(
          client.transcript(sessionId)!.entries.any(isAssistantReply),
          isTrue,
          reason:
              'the reconnect must not lose the visible transcript: '
              '${_clientDiagnostics(client)}',
        );

        // 10. A second prompt still streams.
        final second = await client
            .sendCommand(sessionId, 'prompt', args: {'text': 'second prompt'})
            .timeout(promptTimeout);
        expect(
          second.ok,
          isTrue,
          reason: 'the second prompt must be accepted: ${second.error}',
        );
        await waitUntil(
          () => reconnectedTaps()
              .expand((tap) => tap.eventPayloads())
              .any((payload) => payload['kind'] == 'message'),
          'the second reply to stream after the restart',
          timeout: promptTimeout,
          diagnostics: () =>
              'pi: ${pi.diagnostics()}\n${_clientDiagnostics(client!)}',
        );
        final secondMessage = reconnectedTaps()
            .expand((tap) => tap.eventPayloads())
            .firstWhere(
              (payload) =>
                  payload['kind'] == 'message' &&
                  (payload['message']! as Map)['role'] == 'assistant',
            );
        expect(
          jsonEncode(secondMessage),
          contains(fauxText),
          reason: 'the second reply must carry the faux provider text',
        );
      } finally {
        // Tear down on every path: close the client, kill each child by the pid
        // we spawned (never a `pkill` pattern), then remove the temp dirs.
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
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'a tools recipe relays a tool block paired with its result through the live relay',
    () async {
      // The seam nothing else covers: the bridge relays a `toolResult`, the
      // client stores it live, and `deriveBlocks` pairs it into the call. A
      // count-only assertion would pass if the bridge dropped every result.
      final attach = await attachLive(
        fauxMode: 'tools',
        fauxToolContent: 'FAUX_TOOL_CONTENT\nline two\n',
        extraEnv: {'PI_DROID_FAUX_TEXT': fauxText},
      );
      try {
        final prompt = await attach.client
            .sendCommand(
              attach.sessionId,
              'prompt',
              args: {'text': 'use a tool'},
            )
            .timeout(promptTimeout);
        expect(
          prompt.ok,
          isTrue,
          reason: 'the prompt must be accepted: ${prompt.error}',
        );
        await waitUntil(
          () =>
              attach.client.transcript(attach.sessionId)?.agentState ==
              'settled',
          'the tools turn to settle',
          timeout: promptTimeout,
          diagnostics: () => clientDiagnostics(attach.client),
        );

        // The result reached the client as a relayed `toolResult` message...
        final entries = attach.client.transcript(attach.sessionId)!.entries;
        bool isToolResult(Object? entry) {
          if (entry is! Map) return false;
          final role = entry['message'] is Map
              ? (entry['message']! as Map)['role']
              : entry['role'];
          return role == 'toolResult';
        }

        expect(
          entries.any(isToolResult),
          isTrue,
          reason:
              'the live relay must carry the toolResult: '
              '${clientDiagnostics(attach.client)}',
        );

        // ...and exactly one tool block carries it. A broken pairing renders
        // the result twice (call block + orphan), so the length is the guard.
        final blocks = deriveBlocks(entries);
        final tools = blocks
            .where((block) => block.kind == TranscriptBlockKind.tool)
            .toList();
        expect(
          tools,
          hasLength(1),
          reason:
              'one call must pair into one block, got '
              '${tools.map((block) => block.id).toList()}',
        );
        expect(tools.single.toolName, 'read');
        expect(
          tools.single.toolResult,
          isNotNull,
          reason: 'the result must pair with its call, not render as an orphan',
        );
        expect(tools.single.text, contains('FAUX_TOOL_CONTENT'));
      } finally {
        await attach.teardown();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a missing toolchain binary fails with an actionable message', () async {
    // The suite spawns `node` and `pi`; on a machine without the PC-side
    // toolchain the raw ProcessException must still name the missing binary and
    // where it comes from.
    await expectLater(
      spawn(
        'pi-droid-definitely-not-a-real-binary',
        const [],
        workingDirectory: Directory.current.path,
        environment: const {},
        label: 'node serve',
      ),
      throwsA(
        isA<TestFailure>().having(
          (failure) => failure.message,
          'message',
          allOf(
            contains('node serve'),
            contains('pi-droid-definitely-not-a-real-binary'),
            contains('PC-side toolchain'),
          ),
        ),
      ),
    );
  });
}

String _clientDiagnostics(HubClient client) => clientDiagnostics(client);
