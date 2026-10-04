/// Scans a QR code and resolves the decoded string.
///
/// This is the only place the app names the `mobile_scanner` plugin. The shell
/// takes an optional `scanQr` callback defaulting to [scanPairingQr], so tests
/// inject a fake and `main.dart` stays plugin-free — the same seam
/// [pickGalleryImage] uses.
///
/// [scanPairingQr] resolves the **first** decoded value, or `null` when the
/// user backs out. A camera permission denial or other plugin error renders
/// inside the route through [MobileScanner.errorBuilder] and pops `null`; it
/// never throws into the caller.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Opens the camera and resolves the first barcode's raw value, or `null`.
typedef QrScanner = Future<String?> Function(BuildContext context);

/// The default scanner: a full-screen route that pops the first decoded value.
Future<String?> scanPairingQr(BuildContext context) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(builder: (_) => const _QrScannerRoute()),
  );
}

class _QrScannerRoute extends StatefulWidget {
  const _QrScannerRoute();

  @override
  State<_QrScannerRoute> createState() => _QrScannerRouteState();
}

class _QrScannerRouteState extends State<_QrScannerRoute> {
  /// Guards against a double pop: `onDetect` can fire more than once before the
  /// route is torn down, and the error builder can race an already-decoded
  /// value.
  bool _popped = false;

  void _pop(String? value) {
    if (_popped) return;
    _popped = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan pairing QR'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => _pop(null),
        ),
      ),
      body: MobileScanner(
        onDetect: (capture) {
          for (final barcode in capture.barcodes) {
            final value = barcode.rawValue;
            if (value != null && value.isNotEmpty) {
              _pop(value);
              return;
            }
          }
        },
        // A denial must be visible: without this the route would be a silent
        // black screen (the plugin's default is a bare error icon).
        errorBuilder: (context, error) =>
            _ScannerError(error: error, onClose: () => _pop(null)),
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.error, required this.onClose});

  final MobileScannerException error;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              color: Colors.white,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              'Camera unavailable. Grant the camera permission and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onClose, child: const Text('Close')),
          ],
        ),
      ),
    );
  }
}
