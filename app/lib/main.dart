import 'package:flutter/material.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/hub_socket.dart';
import 'package:pi_droid/client/scheduler.dart';
import 'package:pi_droid/client/secure_token_store.dart';
import 'package:pi_droid/platform/android_notifications.dart';
import 'package:pi_droid/ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // One store, two keys: the pairing token and the remembered endpoint.
  final store = SecureTokenStore();
  final notifications = AndroidNotificationPresenter();
  // A notification tap that cold-started the app carries its session id. It is
  // passed to the shell, which opens it only once the hub has authenticated the
  // connection — subscribing here, before `hello` is answered, would be closed
  // 4002.
  final initialSessionId = await notifications.getLaunchSession();
  runApp(
    PiDroidApp(
      client: HubClient(
        socketFactory: dialHubSocket,
        scheduler: TimerHubScheduler(),
        tokenStore: store,
        // The client coalesces internally; this is the frame cadence the widget
        // actually rebuilds at.
        frameInterval: const Duration(milliseconds: 16),
      ),
      tokenStore: store,
      notifications: notifications,
      initialSessionId: initialSessionId,
    ),
  );
}
