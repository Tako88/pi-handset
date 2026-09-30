/// The minimal WebSocket surface the hub client uses, plus a `dart:io` adapter.
///
/// The client depends only on [HubSocket]/[HubSocketFactory]; tests substitute a
/// fake, and production wires [dialHubSocket] (the only place `dart:io` is
/// touched). `dart:io` is not Flutter, so the tests still run without a binding.
library;

import 'dart:async';
import 'dart:io';

/// The close code and reason, available once a socket is done.
class SocketClose {
  final int? code;
  final String? reason;
  const SocketClose(this.code, this.reason);
}

/// The slice of `WebSocket` the client actually uses.
abstract class HubSocket {
  /// Inbound frames: `String` for text frames, `List<int>` for binary.
  Stream<Object?> get messages;

  /// Completes with the close code/reason when the socket is done.
  Future<SocketClose> get closed;

  void send(String data);

  Future<void> close([int? code, String? reason]);
}

typedef HubSocketFactory = Future<HubSocket> Function(Uri url);

/// Production factory: dials `ws://host:port` with `dart:io`.
Future<HubSocket> dialHubSocket(Uri url) async =>
    IoHubSocket(await WebSocket.connect(url.toString()));

/// Adapts a `dart:io` [WebSocket] to [HubSocket].
class IoHubSocket implements HubSocket {
  IoHubSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<Object?> get messages => _socket;

  @override
  Future<SocketClose> get closed => _socket.done.then(
    (_) => SocketClose(_socket.closeCode, _socket.closeReason),
  );

  @override
  void send(String data) => _socket.add(data);

  @override
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);
}
