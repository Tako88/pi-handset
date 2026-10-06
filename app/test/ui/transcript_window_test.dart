// The transcript window's index math — pure, no widget, no binding. The window
// is a suffix of the already-loaded blocks: the list opens at the newest
// windowBlocks blocks and only grows upward, so everything here is arithmetic
// over a block list.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_models.dart';
import 'package:pi_droid/client/transcript.dart';
import 'package:pi_droid/ui/transcript_view.dart';

TranscriptBlock textBlock(String id) =>
    TranscriptBlock(kind: TranscriptBlockKind.text, id: id, text: id);

List<TranscriptBlock> blocks(String prefix, int count) => [
  for (var i = 0; i < count; i++) textBlock('$prefix$i'),
];

void main() {
  final t = SessionTranscript(blocks: blocks('b', 200));

  group('transcriptItemCount', () {
    test('a window start renders only the suffix from there', () {
      expect(transcriptItemCount(t, windowStart: 170), 30);
      expect(transcriptItemCount(t), 200);
    });

    test('the trailing synthetic rows are counted on top of the window', () {
      final streaming = t.copyWith(
        streaming: true,
        streamingText: 'arriving',
        streamingThinking: 'reasoning',
      );
      expect(transcriptItemCount(streaming, windowStart: 170), 32);
    });
  });

  group('transcriptListIndexOf', () {
    test('a block inside the window maps to its window-relative index', () {
      expect(transcriptListIndexOf(t, 'b199', windowStart: 170), 29);
    });

    test('a block above the window names no list index', () {
      expect(transcriptListIndexOf(t, 'b169', windowStart: 170), isNull);
    });

    test(
      'the truncation row shifts the index only when the window reaches 0',
      () {
        final truncated = SessionTranscript(
          blocks: blocks('b', 200),
          truncated: true,
        );
        expect(transcriptListIndexOf(truncated, 'b0', windowStart: 0), 1);
        expect(transcriptListIndexOf(truncated, 'b170', windowStart: 170), 0);
      },
    );
  });

  group('transcriptWindowStartAfter', () {
    test('an empty old list opens at the newest window', () {
      expect(
        transcriptWindowStartAfter(
          oldBlocks: const [],
          newBlocks: blocks('b', 200),
          prepend: false,
          windowStart: 0,
        ),
        170,
      );
    });

    test('an append keeps the window start', () {
      expect(
        transcriptWindowStartAfter(
          oldBlocks: blocks('b', 60),
          newBlocks: blocks('b', 61),
          prepend: false,
          windowStart: 30,
        ),
        30,
      );
    });

    test('a prepend re-anchors the rendered start on the same block', () {
      final old = blocks('b', 60);
      final now = [...blocks('older', 20), ...old];
      expect(
        transcriptWindowStartAfter(
          oldBlocks: old,
          newBlocks: now,
          prepend: true,
          windowStart: 30,
        ),
        50,
      );
    });

    test('a prepend into an open window renders the new page', () {
      final old = blocks('b', 60);
      final now = [...blocks('older', 20), ...old];
      expect(
        transcriptWindowStartAfter(
          oldBlocks: old,
          newBlocks: now,
          prepend: true,
          windowStart: 0,
        ),
        0,
      );
    });

    test(
      'a rebuild-shaped append keeps the window start on the same block',
      () {
        final old = blocks('b', 60);
        final now = [
          ...blocks('b', 10),
          textBlock('x1'),
          textBlock('x2'),
          ...old.sublist(10),
          textBlock('b60'),
        ];
        expect(
          transcriptWindowStartAfter(
            oldBlocks: old,
            newBlocks: now,
            prepend: false,
            windowStart: 30,
          ),
          32,
          reason: 'the two inserted rows shift the still-current block by two',
        );
        expect(
          transcriptWindowStartAfter(
            oldBlocks: old,
            newBlocks: now,
            prepend: false,
            windowStart: 0,
          ),
          0,
        );
      },
    );

    test(
      'a replacement whose anchor does not survive opens at the newest window',
      () {
        expect(
          transcriptWindowStartAfter(
            oldBlocks: blocks('b', 60),
            newBlocks: blocks('n', 12),
            prepend: false,
            windowStart: 30,
          ),
          0,
        );
      },
    );
  });
}
