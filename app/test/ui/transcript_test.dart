// Transcript: the B0 mitigation. A streaming message renders as plain `Text`
// (cheap to rebuild per frame); the same message once complete renders through
// `MarkdownBody`. Every message is wrapped in a `RepaintBoundary`, and the list
// is lazy — a long transcript must not build (or markdown-parse) every row.

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/ui/transcript_view.dart';

/// A `List` that records how many elements the view read. A non-lazy view walks
/// every entry on every build; a lazy one reads only what it is asked to show.
class CountingList extends ListBase<Object?> {
  CountingList(this._inner);

  final List<Object?> _inner;
  int reads = 0;

  @override
  int get length => _inner.length;

  @override
  set length(int value) => _inner.length = value;

  @override
  Object? operator [](int index) {
    reads++;
    return _inner[index];
  }

  @override
  void operator []=(int index, Object? value) => _inner[index] = value;
}

Widget wrap(SessionTranscript transcript) => MaterialApp(
  home: Scaffold(body: TranscriptView(transcript: transcript)),
);

void main() {
  testWidgets('a streaming message renders as plain text, not markdown', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const SessionTranscript(streamingText: '**bold**', streaming: true),
      ),
    );

    expect(find.text('**bold**'), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
  });

  testWidgets('the same message after completion renders as markdown', (
    tester,
  ) async {
    const completed = SessionTranscript(
      entries: [
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': '**bold**'},
          ],
        },
      ],
    );

    await tester.pumpWidget(wrap(completed));

    // The raw markdown source must be gone and the parsed content present: a
    // stub that renders the raw text would also satisfy `MarkdownBody exists`.
    expect(find.text('**bold**'), findsNothing);
    expect(find.textContaining('bold', findRichText: true), findsOneWidget);
  });

  testWidgets('only visible rows build — a long transcript is lazy', (
    tester,
  ) async {
    final entries = CountingList(
      List<Object?>.generate(
        200,
        (i) => {'type': 'assistant', 'text': 'message $i'},
      ),
    );

    await tester.pumpWidget(wrap(SessionTranscript(entries: entries)));
    await tester.pump();

    // A non-lazy view walks all 200 entries every build (and rebuilds them on
    // every coalesced frame); a lazy one reads only the rows it shows.
    expect(entries.reads, lessThan(entries.length));
    expect(find.text('message 0'), findsOneWidget);
  });

  testWidgets('each message is wrapped in a RepaintBoundary', (tester) async {
    final user = {'type': 'user', 'text': 'hello'};
    final assistant = {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'world'},
      ],
    };

    await tester.pumpWidget(
      wrap(SessionTranscript(entries: [user, assistant])),
    );

    expect(find.byType(MessageBubble), findsNWidgets(2));
    for (final entry in [user, assistant]) {
      final boundary = find.byKey(ObjectKey(entry));
      expect(boundary, findsOneWidget);
      expect(
        find.descendant(
          of: boundary,
          matching: find.byType(MessageBubble),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('a row key is stable when an entry is prepended', (tester) async {
    final a = {'type': 'user', 'text': 'a'};
    final b = {'type': 'assistant', 'text': 'b'};

    await tester.pumpWidget(wrap(SessionTranscript(entries: [a])));
    expect(find.byKey(ObjectKey(a)), findsOneWidget);

    // A positional key would renumber every row on a prepend, defeating the
    // state/boundary stability the keys exist for.
    await tester.pumpWidget(wrap(SessionTranscript(entries: [b, a])));
    expect(find.byKey(ObjectKey(a)), findsOneWidget);
    expect(find.byKey(ObjectKey(b)), findsOneWidget);
  });
}
