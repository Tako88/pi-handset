import 'package:flutter/material.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/hub_socket.dart';
import 'package:pi_droid/client/scheduler.dart';
import 'package:pi_droid/client/secure_token_store.dart';
import 'package:pi_droid/ui/app_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // One store, two keys: the pairing token and the remembered endpoint.
  final store = SecureTokenStore();
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
    ),
  );
}
