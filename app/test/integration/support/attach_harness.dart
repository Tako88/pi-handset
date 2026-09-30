// Shared machinery for the app's *attach* integration tests: spawn a real hub
// and a real pi, pair, tap the wire, and await conditions with bounded waits.
//
// Extracted from `test/integration/attach_path_test.dart` (M10b) when the
// live-provider variant (M10c) needed the same scaffolding. It is a support
// file, not a test: `flutter test` discovers `*_test.dart`, so living under
// `test/integration/support/` keeps it out of the default suite.
//
// Every wait here is bounded — a hang must become a failure, never a stalled
// suite — and every child is killed by the pid we spawned, never a `pkill`
// pattern (see the project memory on `pgrep -f` self-matching).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/hub_socket.dart';

/// A real pi boots slower than any fake. Generous, but bounded.
const Duration bootTimeout = Duration(seconds: 30);
const Duration reconnectTimeout = Duration(seconds: 60);
const Duration exitTimeout = Duration(seconds: 15);

/// `pi-droid pairing code: XXXX-XXXX (valid for 5 minutes)`.
final RegExp pairingCodePattern =
    RegExp(r'pairing code: ([0-9A-Z]{4}-[0-9A-Z]{4})');

/// Polls a predicate until it holds or the timeout elapses, then fails with
/// [diagnostics] rather than letting a dead run hang the suite.
Future<void> waitUntil(
  bool Function() predicate,
  String what, {
  required Duration timeout,
  String Function()? diagnostics,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  final extra = diagnostics == null ? '' : '\n${diagnostics()}';
  fail('timed out after ${timeout.inSeconds}s waiting for $what$extra');
}

/// A spawned child, with both streams drained (an undrained pipe fills and
/// blocks the child) and a bounded kill.
class Child {
  Child(this.process) {
    stdoutSub = process.stdout.transform(utf8.decoder).listen(stdout.write);
    stderrSub = process.stderr.transform(utf8.decoder).listen(stderr.write);
  }

  final Process process;
  final StringBuffer stdout = StringBuffer();
  final StringBuffer stderr = StringBuffer();
  late final StreamSubscription<String> stdoutSub;
  late final StreamSubscription<String> stderrSub;

  int get pid => process.pid;

  String diagnostics() {
    String tail(StringBuffer buffer) {
      final text = buffer.toString().trim();
      return text.length <= 1500 ? text : '...${text.substring(text.length - 1500)}';
    }

    return 'pid=$pid stdout="${tail(stdout)}" stderr="${tail(stderr)}"';
  }

  Future<void> kill(ProcessSignal signal) async {
    process.kill(signal);
    try {
      await process.exitCode.timeout(exitTimeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // Unreapable: nothing more can be done; teardown must not itself hang.
      }
    }
    await stdoutSub.cancel();
    await stderrSub.cancel();
  }
}

Future<Child> spawn(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
  required String label,
}) async {
  try {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: true,
    );
    return Child(process);
  } on ProcessException catch (error) {
    // A missing binary is the common failure on a machine without the PC-side
    // toolchain; say which one and where it comes from, not just the errno.
    final missing =
        error.errorCode == 2 || error.message.contains('No such file');
    if (missing) {
      fail(
        'could not start $label: `$executable` is not on PATH. This test needs '
        'the PC-side toolchain (`node` >= 22.19 and the `pi` CLI from `pc/`); '
        'install it, or run this suite on a machine that has it.',
      );
    }
    fail('$label could not start ($executable): ${error.message}');
  }
}

Future<int> freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Map<String, Object?>? readDiscovery(String runtimeDir) {
  try {
    final raw = File('$runtimeDir/pi-droid/supervisor.json').readAsStringSync();
    final parsed = jsonDecode(raw);
    if (parsed is Map) return parsed.cast<String, Object?>();
  } on FormatException {
    // Mid-rename or corrupt; the hub writes temp-file + rename, so a retry
    // sees a whole record.
  } on FileSystemException {
    // Not published yet.
  }
  return null;
}

/// One dial's frames, in arrival order. The tap observes exactly the frames the
/// client consumes; it does not change delivery.
class Tap {
  final List<Map<String, Object?>> inbound = [];
  final List<Map<String, Object?>> outbound = [];

  List<Map<String, Object?>> outboundOfType(String type) =>
      outbound.where((message) => message['type'] == type).toList();

  /// Every relayed event payload, in wire order.
  List<Map<String, Object?>> eventPayloads() => inbound
      .where((message) => message['type'] == 'event')
      .map((message) => (message['payload']! as Map).cast<String, Object?>())
      .toList();
}

/// Wraps the production [IoHubSocket] to record frames; every call delegates.
class TapSocket implements HubSocket {
  TapSocket(this._inner, this._tap);

  final HubSocket _inner;
  final Tap _tap;

  @override
  late final Stream<Object?> messages = _inner.messages.map((frame) {
    if (frame is String) {
      try {
        final decoded = jsonDecode(frame);
        if (decoded is Map) _tap.inbound.add(decoded.cast<String, Object?>());
      } on FormatException {
        // The client reports a malformed frame; the tap must not mask it.
      }
    }
    return frame;
  });

  @override
  Future<SocketClose> get closed => _inner.closed;

  @override
  void send(String data) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) _tap.outbound.add(decoded.cast<String, Object?>());
    } on FormatException {
      // Same.
    }
    _inner.send(data);
  }

  @override
  Future<void> close([int? code, String? reason]) => _inner.close(code, reason);
}

String clientDiagnostics(HubClient client) {
  final state = client.state;
  final transcripts = state.transcripts.entries
      .map(
        (entry) =>
            '${entry.key}{state=${entry.value.agentState}, '
            'streaming=${entry.value.streaming}, '
            'buffer="${entry.value.streamingText}", '
            'entries=${entry.value.entries.length}, '
            'historyLoaded=${entry.value.historyLoaded}}',
      )
      .join(', ');
  return 'client{status=${state.status}, error=${state.lastError}, '
      'sessions=${state.sessions.map((s) => s.sessionId).toList()}, '
      'active=${state.activeSessionId}, transcripts=[$transcripts]}';
}
