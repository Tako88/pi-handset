// The live status label. `Working…` while a turn runs with no phase, `Thinking…`
// only once the bridge actually signalled thinking, `Responding…` once text
// streams, and nothing when idle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/transcript.dart';
import 'package:pi_droid/ui/status_indicator.dart';
import 'package:pi_droid/ui/theme.dart';

SessionTranscript transcriptWithTool({String? toolName = 'read', Object? result}) =>
    SessionTranscript(
      agentState: 'running',
      blocks: [
        TranscriptBlock(
          kind: TranscriptBlockKind.tool,
          id: 'tool:call-1',
          toolName: toolName,
          toolResult: result,
        ),
      ],
    );

void main() {
  test('the label is null when the agent is idle', () {
    expect(
      statusLabel(const SessionTranscript(agentState: 'idle')),
      isNull,
    );
  });

  test('the label is null when the agent has settled', () {
    expect(
      statusLabel(const SessionTranscript(agentState: 'settled')),
      isNull,
    );
  });

  test('the label is Working… while running with no phase', () {
    expect(
      statusLabel(const SessionTranscript(agentState: 'running')),
      'Working…',
    );
  });

  test('the label is Thinking… once the phase frame arrived', () {
    expect(
      statusLabel(
        const SessionTranscript(agentState: 'running', thinking: true),
      ),
      'Thinking…',
    );
  });

  test('the label is Responding… once text streams', () {
    expect(
      statusLabel(
        const SessionTranscript(agentState: 'running', streamingText: 'hi'),
      ),
      'Responding…',
    );
  });

  test('responding text takes precedence over a stale thinking phase', () {
    expect(
      statusLabel(
        const SessionTranscript(
          agentState: 'running',
          thinking: true,
          streamingText: 'hi',
        ),
      ),
      'Responding…',
    );
  });

  test('a slow model that never emits a phase must not say Thinking', () {
    expect(
      statusLabel(const SessionTranscript(agentState: 'running')),
      'Working…',
    );
  });

  test('the label is Running <tool>… while the last tool block is unresolved', () {
    expect(statusLabel(transcriptWithTool()), 'Running read…');
  });

  test('a resolved tool block does not say Running', () {
    expect(
      statusLabel(
        transcriptWithTool(result: const {'role': 'toolResult'}),
      ),
      'Working…',
    );
  });

  test('a tool block followed by a notice is not Running', () {
    // An error without a settle ([tool, notice]) must not poison the label: the
    // trailing notice means no tool is the current phase.
    expect(
      statusLabel(
        SessionTranscript(
          agentState: 'running',
          blocks: [
            const TranscriptBlock(
              kind: TranscriptBlockKind.tool,
              id: 'tool:call-1',
              toolName: 'read',
            ),
            const TranscriptBlock(
              kind: TranscriptBlockKind.notice,
              id: 'n1',
              text: 'model overloaded',
            ),
          ],
        ),
      ),
      'Working…',
    );
  });

  test('an abandoned tool block followed by streaming text says Responding', () {
    // [tool(null), text] while streaming: the tool was abandoned and the turn
    // continued, so the trailing block decides the phase.
    expect(
      statusLabel(
        SessionTranscript(
          agentState: 'running',
          streamingText: 'hi',
          blocks: [
            const TranscriptBlock(
              kind: TranscriptBlockKind.tool,
              id: 'tool:call-1',
              toolName: 'read',
            ),
            const TranscriptBlock(
              kind: TranscriptBlockKind.text,
              id: 't1',
              text: 'more',
            ),
          ],
        ),
      ),
      'Responding…',
    );
  });

  test('Running takes precedence over Thinking and Responding', () {
    expect(
      statusLabel(
        SessionTranscript(
          agentState: 'running',
          thinking: true,
          streamingText: 'hi',
          blocks: [
            const TranscriptBlock(
              kind: TranscriptBlockKind.tool,
              id: 'tool:call-1',
              toolName: 'read',
            ),
          ],
        ),
      ),
      'Running read…',
    );
  });

  testWidgets('the widget renders the label and hides itself when idle', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: piTheme(Brightness.dark),
        home: const Scaffold(
          body: Column(
            children: [
              StatusIndicator(
                transcript: SessionTranscript(agentState: 'running'),
              ),
              StatusIndicator(
                transcript: SessionTranscript(agentState: 'idle'),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Working…'), findsOneWidget);
  });
}
