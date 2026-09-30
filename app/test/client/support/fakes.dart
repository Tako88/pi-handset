// Shared test doubles for the hub client.
//
// AGENTS.md prefers fakes over mocks: these are small in-process implementations
// of the client's injected seams, not recorded interactions. Nothing here dials
// a socket, schedules a real timer, or sleeps — the client is driven entirely by
// `FakeHubSocket`, `FakeScheduler`, `FakeSocketFactory` and `InMemoryTokenStore`.

import 'dart:async';
import 'dart:convert';

import 'package:pi_droid/client/endpoint_store.dart';
import 'package:pi_droid/client/hub_socket.dart';
import 'package:pi_droid/client/scheduler.dart';
import 'package:pi_droid/client/token_store.dart';

/// An in-memory [TokenStore] for tests, holding both the token and the
/// remembered endpoint. Lives here, not in `lib/`, because a test double should
/// not ship in the app tree.
class InMemoryTokenStore implements TokenStore {
  String? _token;
  HubEndpoint? _endpoint;

  InMemoryTokenStore({String? initial, HubEndpoint? initialEndpoint})
    : _token = initial,
      _endpoint = initialEndpoint;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async {
    _token = token;
  }

  @override
  Future<void> clear() async {
    _token = null;
  }

  @override
  Future<HubEndpoint?> readEndpoint() async => _endpoint;

  @override
  Future<void> writeEndpoint(HubEndpoint endpoint) async {
    _endpoint = endpoint;
  }

  @override
  Future<void> clearEndpoint() async {
    _endpoint = null;
  }
}

/// A [TokenStore] whose token write blocks until [gate] completes. Lets a test
/// observe the window between `paired` arriving and the token being persisted.
class GatedTokenStore implements TokenStore {
  final Completer<void> gate = Completer<void>();
  String? _token;
  HubEndpoint? _endpoint;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async {
    await gate.future;
    _token = token;
  }

  @override
  Future<void> clear() async {
    _token = null;
  }

  @override
  Future<HubEndpoint?> readEndpoint() async => _endpoint;

  @override
  Future<void> writeEndpoint(HubEndpoint endpoint) async {
    _endpoint = endpoint;
  }

  @override
  Future<void> clearEndpoint() async {
    _endpoint = null;
  }
}

/// A WebSocket the test controls frame by frame.
class FakeHubSocket implements HubSocket {
  final StreamController<Object?> _messages = StreamController<Object?>();
  final Completer<SocketClose> _closed = Completer<SocketClose>();

  /// Every frame the client sent, in order.
  final List<String> sent = <String>[];

  /// True once the client itself called [close].
  bool closedByClient = false;

  @override
  Stream<Object?> get messages => _messages.stream;

  @override
  Future<SocketClose> get closed => _closed.future;

  /// When true, [send] throws, simulating a write to a closing socket.
  bool throwOnSend = false;

  @override
  void send(String data) {
    if (throwOnSend) throw StateError('socket is closing');
    sent.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closedByClient = true;
    _finish(SocketClose(code, reason));
  }

  /// Pushes one inbound frame; a map is JSON-encoded, a string is sent verbatim.
  void receive(Object? frame) {
    _messages.add(frame is String ? frame : jsonEncode(frame));
  }

  /// Simulates the peer (or the network) closing the connection.
  void remoteClose(int? code, [String? reason]) =>
      _finish(SocketClose(code, reason));

  /// The most recently sent frame, decoded.
  Map<String, Object?> get lastSent =>
      (jsonDecode(sent.last) as Map).cast<String, Object?>();

  /// Every sent frame, decoded.
  List<Map<String, Object?>> get sentFrames => sent
      .map((frame) => (jsonDecode(frame) as Map).cast<String, Object?>())
      .toList();

  void _finish(SocketClose close) {
    if (_closed.isCompleted) return;
    _closed.complete(close);
    if (!_messages.isClosed) _messages.close();
  }
}

/// A scheduler whose timers fire only when the test says so.
class FakeScheduler implements HubScheduler {
  final List<FakeTimer> timers = <FakeTimer>[];

  @override
  HubTimer schedule(
    Duration delay,
    void Function() task, {
    HubTimerKind kind = HubTimerKind.notify,
  }) {
    final timer = FakeTimer(delay, task, kind);
    timers.add(timer);
    return timer;
  }

  List<FakeTimer> _ofKind(HubTimerKind kind) =>
      timers.where((timer) => timer.kind == kind).toList();

  /// Reconnect waits, never frame notifies or watchdogs.
  List<FakeTimer> get reconnectTimers => _ofKind(HubTimerKind.reconnect);

  /// Backoff waits currently pending, in scheduling order.
  List<Duration> get reconnectDelays =>
      reconnectTimers.map((timer) => timer.delay).toList();

  List<FakeTimer> get authTimers => _ofKind(HubTimerKind.auth);
  List<FakeTimer> get commandTimers => _ofKind(HubTimerKind.command);
  List<FakeTimer> get notifyTimers => _ofKind(HubTimerKind.notify);

  /// Fires every pending notification timer, in order. Coalescing timers are
  /// the only kind existing tests mean by "flush"; watchdogs and reconnects are
  /// fired explicitly.
  void flushNotifications() {
    for (final timer in List<FakeTimer>.of(notifyTimers)) {
      timer.fire();
    }
  }

  /// Fires the auth watchdog(s), simulating the bounded wait elapsing.
  void fireAuthWatchdog() {
    for (final timer in List<FakeTimer>.of(authTimers)) {
      timer.fire();
    }
  }

  /// Fires per-command timeouts.
  void fireCommandTimeouts() {
    for (final timer in List<FakeTimer>.of(commandTimers)) {
      timer.fire();
    }
  }

  void clear() => timers.clear();
}

class FakeTimer implements HubTimer {
  FakeTimer(this.delay, this.task, this.kind);

  final Duration delay;
  final void Function() task;
  final HubTimerKind kind;
  bool cancelled = false;
  bool fired = false;

  void fire() {
    if (cancelled || fired) return;
    fired = true;
    task();
  }

  @override
  void cancel() => cancelled = true;
}

/// A socket factory whose outcome the test scripts per dial.
class FakeSocketFactory {
  final List<FakeHubSocket> sockets = <FakeHubSocket>[];
  final List<Uri> urls = <Uri>[];

  /// Invoked on every dial. Return an [Exception]/[Error] to fail the dial, a
  /// [FakeHubSocket] to make it succeed, or leave null to create a fresh one.
  Object? Function()? onDial;

  FakeHubSocket get last => sockets.last;

  Future<HubSocket> call(Uri url) async {
    urls.add(url);
    final result = onDial?.call();
    if (result == null) {
      final socket = FakeHubSocket();
      sockets.add(socket);
      return socket;
    }
    if (result is HubSocket) {
      if (result is FakeHubSocket) sockets.add(result);
      return result;
    }
    throw result;
  }
}
