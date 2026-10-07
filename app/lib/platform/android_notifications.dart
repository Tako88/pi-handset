/// The concrete [NotificationPresenter], talking to the Android host over one
/// MethodChannel.
///
/// This is the only place in the app that names a platform channel; the app
/// shell depends on the Flutter-free `NotificationPresenter` interface so it
/// stays testable. Native side: `MainActivity.kt` handles every method and
/// `HubConnectionService.kt` provides the foreground service.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../client/notification_presenter.dart';

class AndroidNotificationPresenter implements NotificationPresenter {
  AndroidNotificationPresenter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  /// The one channel name, shared with `MainActivity.kt`.
  static const String channelName = 'pi_handset/notifications';

  final MethodChannel _channel;
  final StreamController<String> _openSessionRequests =
      StreamController<String>.broadcast();

  /// Native pushes `openSession` with a session id when the user taps a
  /// notification while the app is already running.
  Future<Object?> _onMethodCall(MethodCall call) async {
    if (call.method == 'openSession') {
      final sessionId = call.arguments;
      if (sessionId is String && sessionId.isNotEmpty) {
        _openSessionRequests.add(sessionId);
      }
    }
    return null;
  }

  @override
  Stream<String> get openSessionRequests => _openSessionRequests.stream;

  @override
  Future<String?> getLaunchSession() async {
    final sessionId = await _channel.invokeMethod<String>('getLaunchSession');
    return (sessionId == null || sessionId.isEmpty) ? null : sessionId;
  }

  @override
  Future<void> requestPermission() =>
      _channel.invokeMethod<void>('requestNotificationPermission');

  @override
  Future<void> startForeground() =>
      _channel.invokeMethod<void>('startForegroundService');

  @override
  Future<void> stopForeground() =>
      _channel.invokeMethod<void>('stopForegroundService');

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String sessionId,
  }) => _channel.invokeMethod<void>('showNotification', <String, Object?>{
    'id': id,
    'title': title,
    'body': body,
    'sessionId': sessionId,
  });

  @override
  Future<void> cancel({required int id}) =>
      _channel.invokeMethod<void>('cancelNotification', <String, Object?>{
        'id': id,
      });
}
