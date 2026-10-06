/// The pairing page, shared by the boot path (as the root) and the pushed
/// route (over the live session list).
///
/// Only a pushed page is wrapped in the route's `PopScope`, which clears the
/// shell's route latch when the route really pops. The boot root has nothing
/// behind it, so it must not register a pop entry or offer a way back.
library;

import 'package:flutter/material.dart';

import '../client/endpoint_store.dart';
import '../platform/qr_scanner.dart';
import 'pairing_screen.dart';

class PairingPage extends StatelessWidget {
  const PairingPage({
    super.key,
    this.onPopped,
    this.showBack = false,
    required this.onSubmit,
    required this.onScanned,
    required this.onCandidate,
    required this.candidates,
    required this.scanQr,
    this.lastError,
    required this.busy,
    required this.initialHost,
    required this.initialPort,
  });

  /// Called when the pushed route really pops, so the shell can clear its route
  /// latch. Null for the boot root, which is not wrapped in a `PopScope`.
  final VoidCallback? onPopped;

  /// Whether the screen offers a visible way out. True only when the caller
  /// pushed this page over a live session list.
  final bool showBack;

  /// Called with the validated host, port and normalized code.
  final void Function(String host, int port, String code) onSubmit;

  /// Called with the hub-minted candidate list and code after a scan that
  /// carried at least one address.
  final void Function(List<HubEndpoint> candidates, String code) onScanned;

  /// Called when the user taps a candidate row.
  final void Function(HubEndpoint candidate) onCandidate;

  /// The addresses the client is racing (or last raced).
  final List<HubEndpoint> candidates;

  /// Opens the camera and resolves the raw scanned string.
  final QrScanner scanQr;

  /// The client's most recent error, or the bootstrap failure, shown verbatim.
  final String? lastError;

  /// Indicator only; never gates input.
  final bool busy;

  final String initialHost;
  final String initialPort;

  @override
  Widget build(BuildContext context) {
    final screen = PairingScreen(
      showBack: showBack,
      onSubmit: onSubmit,
      onScanned: onScanned,
      onCandidate: onCandidate,
      candidates: candidates,
      scanQr: scanQr,
      lastError: lastError,
      busy: busy,
      initialHost: initialHost,
      initialPort: initialPort,
    );
    final onPopped = this.onPopped;
    if (onPopped == null) return screen;
    return PopScope<void>(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) onPopped();
      },
      child: screen,
    );
  }
}
