/// The pairing screen: host, port and an 8-character pairing code.
///
/// Validation and normalisation reuse the fixture-pinned `normalizeTicket`, so
/// a code accepted here is one the hub accepts. A failure is always visible;
/// the client's `lastError` is surfaced rather than leaving a bare spinner.
library;

import 'package:flutter/material.dart';

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

  static const String missingHostError = 'Enter the hub address.';
  static const String invalidPortError = 'Enter a port between 1 and 65535.';
  static const String invalidCodeError =
      "That pairing code isn't valid. Copy the 8 characters the hub printed.";

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                ),
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
                            child: CircularProgressIndicator(strokeWidth: 2),
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
