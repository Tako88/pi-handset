/// A thin banner so a dropped connection, a dead-end resync or a send failure
/// is never silent. Shown whenever there is an error, whatever the status —
/// not only while disconnected.
library;

import 'package:flutter/material.dart';

class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.child,
    this.error,
    this.dismissedError,
    required this.connected,
    required this.onDismiss,
  });

  /// The content the banner wraps when it shows nothing.
  final Widget child;

  /// The client's most recent error, shown verbatim when present.
  final String? error;

  /// The last error the user dismissed, so the banner does not re-show it.
  final String? dismissedError;

  /// Whether the hub is connected; false shows the reconnect row.
  final bool connected;

  /// Called when the user dismisses the error.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    final showError = error != null && error != dismissedError;
    final showReconnect = !connected;
    if (!showError && !showReconnect) return child;
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.errorContainer,
          padding: const EdgeInsets.only(left: 8, right: 8),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    showError ? error : 'Reconnecting to the hub…',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
              if (showError)
                IconButton(
                  key: const Key('dismiss-error'),
                  icon: const Icon(Icons.close),
                  tooltip: 'Dismiss',
                  onPressed: onDismiss,
                ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
