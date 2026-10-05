// Selection: every committed transcript row is wrapped in a SelectionArea
// whose toolbar adds a "Copy message" item that copies the whole row into the
// injected onCopyText callback. A SelectionArea asserts an Overlay ancestor
// (debugCheckHasOverlay), so every pump here goes through a MaterialApp; a bare
// TranscriptView would assert.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_models.dart';
import 'package:pi_droid/client/tool_view.dart';
import 'package:pi_droid/client/transcript.dart';
import 'package:pi_droid/ui/theme.dart';
import 'package:pi_droid/ui/transcript_blocks.dart';
import 'package:pi_droid/ui/transcript_view.dart';

/// A genuine 1×1 PNG; the widget tests' own Image decode is the validator.
final pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  final copied = <String>[];
  setUp(() => copied.clear());

  Widget wrap(SessionTranscript transcript) => MaterialApp(
    theme: piTheme(Brightness.dark),
    home: Scaffold(
      body: TranscriptView(
        transcript: transcript,
        onLoadOlder: () {},
        onCopyText: copied.add,
      ),
    ),
  );

  TranscriptBlock textBlock(String id, String text) => TranscriptBlock(
    kind: TranscriptBlockKind.text,
    id: id,
    text: text,
  );

  TranscriptBlock toolBlock({
    String id = 'tool:call-1',
    String? toolName = 'read',
    Object? toolArgs = const {'path': '/etc/hostname'},
    Object? toolResult,
    ToolView? toolView,
    bool isError = false,
    String text = '',
  }) => TranscriptBlock(
    kind: TranscriptBlockKind.tool,
    id: id,
    toolName: toolName,
    toolArgs: toolArgs,
    toolResult: toolResult,
    toolView: toolView,
    isError: isError,
    text: text,
  );

  testWidgets('committed rows are selectable', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            textBlock('t1', 'one'),
            textBlock('t2', 'two'),
            toolBlock(text: 'output'),
            TranscriptBlock(
              kind: TranscriptBlockKind.image,
              id: 'i1',
              imageBytes: pngBytes,
            ),
          ],
        ),
      ),
    );

    expect(find.byType(SelectionArea), findsNWidgets(3));
  });

  testWidgets('the streaming row is not selectable', (tester) async {
    await tester.pumpWidget(
      wrap(const SessionTranscript(streamingText: 'partial', streaming: true)),
    );

    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('the live-thinking row is not selectable', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SessionTranscript(streamingThinking: 'hmm', streaming: true),
      ),
    );

    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets(
    'long-pressing a text block offers Copy message and copies the whole message',
    (tester) async {
      await tester.pumpWidget(
        wrap(SessionTranscript(blocks: [textBlock('t1', 'copy me please')])),
      );

      await tester.longPress(
        find.textContaining('copy me please', findRichText: true).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(TranscriptView.copyMessageLabel));
      await tester.pumpAndSettle();

      expect(copied, ['copy me please']);
    },
  );

  testWidgets('Copy message on a diff copies the diff, not the summary', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolName: 'edit',
              toolArgs: const {'path': 'app/foo.dart'},
              text: 'Successfully replaced 1 block(s).',
              toolView: const DiffView(
                path: 'app/foo.dart',
                lines: [
                  DiffLine(diffLineCtx, 'alpha'),
                  DiffLine(diffLineDel, 'beta'),
                  DiffLine(diffLineAdd, 'gamma'),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // The removed line's own Text is a unique, definitely-selectable target.
    await tester.longPress(find.text('beta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(TranscriptView.copyMessageLabel));
    await tester.pumpAndSettle();

    expect(copied, ['edit\n{"path":"app/foo.dart"}\n alpha\n-beta\n+gamma']);
  });

  testWidgets('a tool row still toggles while selectable', (tester) async {
    final result = List.generate(12, (i) => 'line $i').join('\n');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolResult: const {'role': 'toolResult'},
              text: result,
            ),
          ],
        ),
      ),
    );

    expect(find.textContaining('line 0'), findsOneWidget);

    await tester.tap(find.byType(ToolBlock));
    await tester.pumpAndSettle();

    expect(find.textContaining('line 11'), findsOneWidget);
  });

  testWidgets('the per-row area count is bounded by the lazy list', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            for (var i = 0; i < 200; i++) textBlock('b$i', 'block $i'),
          ],
        ),
      ),
    );

    expect(tester.widgetList(find.byType(SelectionArea)).length, lessThan(200));
  });
}
