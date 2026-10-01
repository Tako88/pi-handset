/// The app's platform notification surface, as a seam.
///
/// Deliberately Flutter-free: `app_shell.dart` depends on this interface, tests
/// substitute a fake, and the concrete `AndroidNotificationPresenter` (which
/// talks to the platform over a MethodChannel) is wired only in `main.dart`.
/// The app never names a plugin type.
library;

/// Presents settle notifications and owns the native foreground service.
abstract class NotificationPresenter {
  /// Session ids delivered when the user taps a notification. Each id should be
  /// opened once the client is authenticated.
  Stream<String> get openSessionRequests;

  /// The session a notification tap launched the app for, or null for an
  /// ordinary cold start.
  Future<String?> getLaunchSession();

  /// Requests the runtime notification permission where the OS requires it.
  /// A denial is not fatal: the service still runs and the OS drops the
  /// notifications.
  Future<void> requestPermission();

  /// Starts the native foreground service that keeps the socket alive while the
  /// app is backgrounded. Idempotent from the caller's side.
  Future<void> startForeground();

  /// Stops the foreground service and removes its persistent notification.
  Future<void> stopForeground();

  /// Shows (or replaces, by [id]) a notification. [sessionId] is carried so a
  /// tap can open the right session.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String sessionId,
  });

  /// Dismisses the notification with [id]. Called when the user is looking at
  /// the session it refers to, so a shade entry never outlives its reason to
  /// exist.
  Future<void> cancel({required int id});
}
