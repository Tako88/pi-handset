// Link tapping: a markdown `href` opens in the browser when it is http/https,
// and is ignored otherwise. The guard is pure; the wiring is asserted through
// an injected opener so no platform channel is involved.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/transcript.dart';
import 'package:pi_droid/ui/theme.dart';
import 'package:pi_droid/ui/transcript_blocks.dart';
import 'package:pi_droid/ui/transcript_view.dart';

void main() {
  group('linkUriToOpen', () {
    test('an https link maps to its Uri', () {
      expect(
        linkUriToOpen('https://example.com/a?b=1'),
        Uri.parse('https://example.com/a?b=1'),
      );
    });

    test('an http link maps to its Uri', () {
      expect(
        linkUriToOpen('http://example.com'),
        Uri.parse('http://example.com'),
      );
    });

    test('an anchor is ignored', () {
      expect(linkUriToOpen('#section'), isNull);
    });

    test('a mailto link is ignored', () {
      expect(linkUriToOpen('mailto:someone@example.com'), isNull);
    });

    test('a bare relative path is ignored', () {
      expect(linkUriToOpen('docs/page.md'), isNull);
    });

    test('a scheme-relative href is ignored', () {
      expect(linkUriToOpen('//example.com'), isNull);
    });

    test('an uppercase scheme is accepted', () {
      expect(
        linkUriToOpen('HTTP://example.com'),
        Uri.parse('HTTP://example.com'),
      );
    });

    test('a path-only href is ignored', () {
      expect(linkUriToOpen('/abs/path'), isNull);
      expect(linkUriToOpen('?q=1'), isNull);
    });

    test('a non-http scheme is ignored', () {
      expect(linkUriToOpen('ftp://example.com/file'), isNull);
    });

    test('an empty href is ignored', () {
      expect(linkUriToOpen(''), isNull);
    });

    test('a whitespace-only href is ignored', () {
      expect(linkUriToOpen('   '), isNull);
    });

    test('a null href is ignored', () {
      expect(linkUriToOpen(null), isNull);
    });
  });

  Widget view(String text, Future<void> Function(Uri) onOpenLink) =>
      MaterialApp(
        theme: piTheme(Brightness.dark),
        home: Scaffold(
          body: TranscriptView(
            transcript: SessionTranscript(
              blocks: [
                TranscriptBlock(
                  kind: TranscriptBlockKind.text,
                  id: 'b1',
                  text: text,
                ),
              ],
            ),
            onLoadOlder: () {},
            onOpenLink: onOpenLink,
          ),
        ),
      );

  testWidgets('tapping an http link opens it through the injected opener', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      view(
        'see [tap here](https://example.com/page)',
        (uri) async => opened.add(uri),
      ),
    );

    await tester.tapOnText(find.textRange.ofSubstring('tap here'));
    await tester.pump();

    expect(opened, [Uri.parse('https://example.com/page')]);
  });

  testWidgets('tapping a non-http link does not open anything', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      view(
        'mail [tap here](mailto:someone@example.com)',
        (uri) async => opened.add(uri),
      ),
    );

    await tester.tapOnText(find.textRange.ofSubstring('tap here'));
    await tester.pump();

    expect(opened, isEmpty);
  });
}
