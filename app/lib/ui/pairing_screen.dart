/// The pairing screen: host, port and an 8-character pairing code.
///
/// Validation and normalisation reuse the fixture-pinned `normalizeTicket`, so
/// a code accepted here is one the hub accepts. A failure is always visible;
/// the client's `lastError` is surfaced rather than leaving a bare spinner.
library;

import 'package:flutter/material.dart';

import '../client/endpoint_store.dart';
import '../platform/qr_scanner.dart';
import '../protocol/pairing_uri.dart';
import 'theme.dart';
import '../protocol/ticket.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({
    super.key,
    required this.onSubmit,
    this.initialHost = '',
    this.initialPort = '8787',
    this.initialCode = '',
    this.lastError,
    this.busy = false,
    this.scanQr,
    this.candidates = const [],
    this.onCandidate,
    this.onScanned,
    this.showBack = false,
  });

  /// Called with the validated host, port and normalized code.
  final void Function(String host, int port, String code) onSubmit;

  final String initialHost;
  final String initialPort;
  final String initialCode;

  /// The client's most recent error, shown verbatim when present.
  final String? lastError;

  /// Indicator only; never gates input. The fields and the submit button stay
  /// live while an attempt is in flight, so a background redial can never
  /// dead-end the pairing form. Submitting during an attempt is a restart.
  final bool busy;

  /// Opens the camera and resolves the raw scanned string, or null when the
  /// user backs out. Null hides the Scan QR affordance entirely.
  final QrScanner? scanQr;

  /// The addresses the client is racing (or last raced). Non-empty renders the
  /// one-tap picker so a forced candidate can be retried without retyping.
  final List<HubEndpoint> candidates;

  /// Called when the user taps a candidate row.
  final void Function(HubEndpoint candidate)? onCandidate;

  /// Called with the hub-minted candidate list and code after a scan that
  /// carried at least one address. A code-only (`--no-lan`) scan reports
  /// nothing here — there is no address to race.
  final void Function(List<HubEndpoint> candidates, String code)? onScanned;

  /// Whether to offer a visible way out. True only when the caller pushed this
  /// screen over a live session list; false when it is the whole app before the
  /// first pairing, where there is nothing behind it to go back to. Told by the
  /// caller rather than inferred from connection state, which would be a guess.
  final bool showBack;

  static const String missingHostError = 'Enter the hub address.';
  static const String invalidPortError = 'Enter a port between 1 and 65535.';
  static const String invalidCodeError =
      "That pairing code isn't valid. Copy the 8 characters the hub printed.";
  static const String scanNotPairingError =
      "That QR isn't a pi pairing code.";
  static const String scanUnsupportedVersionError =
      'This QR needs a newer app. Update the app and try again.';
  static const String scanInvalidError =
      'That pairing QR is not valid. Print a fresh one from the hub.';
  static const String scanFailedError = 'Could not scan the QR code. Try again.';
  static const String noAddressHint =
      'No hub address in this QR. Enter the host and port by hand.';

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  late final TextEditingController _host = TextEditingController(
    text: widget.initialHost,
  );
  late final TextEditingController _port = TextEditingController(
    text: widget.initialPort,
  );
  late final TextEditingController _code = TextEditingController(
    text: widget.initialCode,
  );
  String? _error;

  /// A scan that failed to yield a usable pairing URI, shown like [_error].
  String? _scanError;

  /// True when a scanned QR carried no address (`--no-lan`), so the manual form
  /// is the only path.
  bool _noAddress = false;

  /// The candidate row the user last tapped, marked with a check. Purely a
  /// display latch: the tap still reports through [PairingScreen.onCandidate].
  HubEndpoint? _selected;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(PairingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A rejected ticket is single-use and attempt-capped, so retrying the same
    // code is futile: when the client reports a new error, clear the code and
    // let the user type a fresh one.
    if (widget.lastError != null && widget.lastError != oldWidget.lastError) {
      _code.clear();
    }
  }

  void _submit() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = PairingScreen.missingHostError);
      return;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = PairingScreen.invalidPortError);
      return;
    }
    final code = normalizeTicket(_code.text);
    if (code == null) {
      setState(() => _error = PairingScreen.invalidCodeError);
      return;
    }
    setState(() => _error = null);
    widget.onSubmit(host, port, code);
    // A pairing code is single-use and hub attempts are capped, so a spent code
    // must not stay in the field ready to be resubmitted. Cleared here rather
    // than only on a changed `lastError`: an identical repeat failure would
    // otherwise leave it behind.
    _code.clear();
  }

  Future<void> _scan() async {
    final scanQr = widget.scanQr;
    if (scanQr == null) return;
    String? raw;
    try {
      raw = await scanQr(context);
    } catch (_) {
      // A denied camera or a plugin failure must be visible, never an unhandled
      // async throw that blanks the route.
      if (!mounted) return;
      setState(() => _scanError = PairingScreen.scanFailedError);
      return;
    }
    if (!mounted || raw == null) return;
    switch (parsePairingUri(raw)) {
      case PairingFailure(:final error):
        setState(() {
          // A failure replaces any previous scan outcome: a stale no-address
          // hint must not sit beside the error.
          _noAddress = false;
          _scanError = switch (error) {
            pairingErrorUnsupportedVersion =>
              PairingScreen.scanUnsupportedVersionError,
            pairingErrorNotAUri => PairingScreen.scanNotPairingError,
            _ => PairingScreen.scanInvalidError,
          };
        });
      case PairingOk(:final pairing):
        final addresses = pairing.addresses;
        final port = pairing.viewerPort;
        if (addresses.isEmpty || port == null) {
          setState(() {
            _scanError = null;
            _code.text = formatTicketDisplay(pairing.code);
            _noAddress = true;
          });
          return;
        }
        setState(() {
          _scanError = null;
          _noAddress = false;
          _code.text = formatTicketDisplay(pairing.code);
          _host.text = addresses.first.host;
          _port.text = port.toString();
        });
        widget.onScanned?.call(
          [
            for (final address in addresses)
              HubEndpoint(host: address.host, port: port),
          ],
          pairing.code,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Only the pushed route gets a title bar: over the boot root it would be
      // a bar with a back arrow that leads nowhere.
      appBar: widget.showBack
          ? AppBar(
              title: const Text('Pairing'),
              leading: const BackButton(key: Key('pairing-back')),
            )
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Pair with pi', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Text('Run the hub on your PC and paste the code it prints.'),
                const SizedBox(height: 24),
                TextField(
                  key: const Key('pairing-host'),
                  controller: _host,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    hintText: '192.168.1.10',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('pairing-port'),
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Port'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('pairing-code'),
                  controller: _code,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 12,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Pairing code'),
                  // An 8-character code read off another screen: the mono face
                  // and the tracking are what make it checkable at a glance,
                  // and the hub prints it with a dash.
                  style: piMono(fontSize: 16, letterSpacing: 2),
                ),
                if (widget.scanQr != null) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('pairing-scan'),
                    onPressed: _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR'),
                  ),
                ],
                if (widget.candidates.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final candidate in widget.candidates)
                    ListTile(
                      key: Key('pairing-candidate-${candidate.encode()}'),
                      dense: true,
                      leading: const Icon(Icons.lan_outlined),
                      title: Text(candidateLabel(candidate.host)),
                      // A host:port is the machine's name for itself.
                      subtitle: Text(
                        candidate.encode(),
                        style: piMono(
                          fontSize: 12,
                          color: Theme.of(
                            context,
                          ).extension<PiRoles>()!.muted,
                        ),
                      ),
                      selected: candidate == _selected,
                      selectedTileColor: Theme.of(
                        context,
                      ).extension<PiRoles>()!.selectedBg,
                      trailing: candidate == _selected
                          ? Icon(
                              Icons.check,
                              color: Theme.of(
                                context,
                              ).extension<PiRoles>()!.accent,
                            )
                          : null,
                      onTap: () {
                        setState(() => _selected = candidate);
                        widget.onCandidate?.call(candidate);
                      },
                    ),
                ],
                if (_noAddress) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    key: const Key('pairing-no-address'),
                    liveRegion: true,
                    child: const Text(PairingScreen.noAddressHint),
                  ),
                ],
                if (_scanError != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    key: const Key('pairing-scan-error'),
                    liveRegion: true,
                    child: Text(
                      _scanError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    key: const Key('pairing-error'),
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                if (widget.lastError != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    key: const Key('pairing-last-error'),
                    liveRegion: true,
                    child: Text(
                      widget.lastError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('pairing-submit'),
                  onPressed: _submit,
                  child: widget.busy
                      ? Semantics(
                          key: const Key('pairing-busy'),
                          liveRegion: true,
                          label: 'Pairing…',
                          child: SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              // The button's background is `primary`, so the
                              // default (`primary`) indicator is invisible.
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          ),
                        )
                      : const Text('Pair'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
