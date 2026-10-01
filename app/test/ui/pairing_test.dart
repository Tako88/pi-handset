// Pairing: host, port and a pairing code. The code is validated and normalised
// with the shared `normalizeTicket`; an invalid code must be a visible error,
// never a silent no-op.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/ui/pairing_screen.dart';

void main() {
  testWidgets('an empty host shows an error and does not submit', (
    tester,
  ) async {
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: PairingScreen(
          onSubmit: (host, port, code) => submitted = code,
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();

    expect(find.text(PairingScreen.missingHostError), findsOneWidget);
    expect(submitted, isNull);
  });

  testWidgets('a non-numeric port shows an error and does not submit', (
    tester,
  ) async {
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: PairingScreen(
          onSubmit: (host, port, code) => submitted = code,
          initialHost: '10.0.0.2',
          initialPort: 'not-a-port',
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();

    expect(find.text(PairingScreen.invalidPortError), findsOneWidget);
    expect(submitted, isNull);
  });

  testWidgets('a bad pairing code shows an error and does not submit', (
    tester,
  ) async {
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: PairingScreen(
          onSubmit: (host, port, code) => submitted = code,
          initialHost: '10.0.0.2',
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('pairing-code')), 'I-L-O-U!!!');
    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();

    expect(find.text(PairingScreen.invalidCodeError), findsOneWidget);
    expect(submitted, isNull);
  });

  testWidgets('a good pairing code is normalised before submit', (tester) async {
    String? host;
    int? port;
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: PairingScreen(
          onSubmit: (h, p, c) {
            host = h;
            port = p;
            submitted = c;
          },
          initialHost: '10.0.0.2',
          initialPort: '9000',
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('pairing-code')), 'abcd-2345');
    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();

    expect(submitted, 'ABCD2345');
    expect(host, '10.0.0.2');
    expect(port, 9000);
  });

  testWidgets("the client's lastError is surfaced instead of a bare spinner", (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PairingScreen(
          onSubmit: (host, port, code) {},
          lastError: 'timed out waiting for the hub to authenticate',
          busy: true,
        ),
      ),
    );

    expect(
      find.textContaining('timed out waiting for the hub'),
      findsOneWidget,
    );
  });

  testWidgets('the code field suits a mobile keyboard', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: PairingScreen(onSubmit: (host, port, code) {})),
    );

    final code = tester.widget<TextField>(
      find.byKey(const Key('pairing-code')),
    );
    expect(code.autocorrect, isFalse);
    expect(code.enableSuggestions, isFalse);
    expect(code.maxLength, 12);
    final host = tester.widget<TextField>(
      find.byKey(const Key('pairing-host')),
    );
    expect(host.keyboardType, TextInputType.url);
  });

  testWidgets('the error text is a live region', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PairingScreen(
          onSubmit: (host, port, code) {},
          initialHost: '10.0.0.2',
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('pairing-code')), 'I-L-O-U!!!');
    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();

    final semantics = tester.widget<Semantics>(
      find.byKey(const Key('pairing-error')),
    );
    expect(semantics.properties.liveRegion, isTrue);
  });

  testWidgets('a busy pairing screen still lets the user type and submit', (
    tester,
  ) async {
    String? host;
    String? code;
    await tester.pumpWidget(
      MaterialApp(
        home: PairingScreen(
          onSubmit: (h, p, c) {
            host = h;
            code = c;
          },
          initialHost: '10.0.0.2',
          busy: true,
        ),
      ),
    );

    // `busy` is an indicator, never a gate: a background redial must not stop
    // the user from typing or re-pairing.
    await tester.enterText(find.byKey(const Key('pairing-host')), '10.0.0.9');
    await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
    await tester.pump();
    expect(find.text('10.0.0.9'), findsOneWidget);
    expect(find.text('ABCD2345'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();

    expect(host, '10.0.0.9');
    expect(code, 'ABCD2345');
  });

  testWidgets('submitting clears the spent code so it cannot be retried', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PairingScreen(
          onSubmit: (host, port, code) {},
          initialHost: '10.0.0.2',
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();

    // A ticket is single-use and hub attempts are capped, so a code left in the
    // field can only be resubmitted into a failure. The clear has to happen on
    // submit, not only when the error text changes: an identical repeat failure
    // would leave it behind.
    expect(find.text('ABCD2345'), findsNothing);
  });

  testWidgets('the busy spinner is announced', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PairingScreen(onSubmit: (host, port, code) {}, busy: true),
      ),
    );

    final semantics = tester.widget<Semantics>(
      find.byKey(const Key('pairing-busy')),
    );
    expect(semantics.properties.liveRegion, isTrue);
    expect(semantics.properties.label, isNotNull);
  });

  testWidgets('a new client error clears the code so a fresh one can be typed', (
    tester,
  ) async {
    Widget screen(String? lastError) => MaterialApp(
      home: PairingScreen(
        onSubmit: (host, port, code) {},
        initialHost: '10.0.0.2',
        lastError: lastError,
      ),
    );

    await tester.pumpWidget(screen(null));
    await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
    expect(find.text('ABCD2345'), findsOneWidget);

    // A pairing ticket is single-use: retrying the same code is futile, so the
    // rejected code must be cleared for a new one.
    await tester.pumpWidget(screen('the hub rejected the pairing code'));
    await tester.pump();

    expect(find.text('ABCD2345'), findsNothing);
    expect(
      find.textContaining('the hub rejected the pairing code'),
      findsOneWidget,
    );
  });
}
