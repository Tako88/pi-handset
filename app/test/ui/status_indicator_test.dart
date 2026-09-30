// The live status label. `Working…` while a turn runs with no phase, `Thinking…`
// only once the bridge actually signalled thinking, `Responding…` once text
// streams, and nothing when idle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/ui/status_indicator.dart';

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

  testWidgets('the widget renders the label and hides itself when idle', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
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
