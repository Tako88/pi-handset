/// The transcript menu's thinking-level and model actions, lifted out of the
/// app shell.
///
/// Owns the two commands driven from the ⋮ menu's value pickers: it reads the
/// session's current value, shows the picker, sends the chosen reference, and
/// surfaces a refusal. Each current value is read at the point the original
/// code read it — before the picker's await for the thinking level, after the
/// model list resolves for the model — so a value the hub changed mid-flight is
/// not sent stale. A pure action layer: all it needs from the shell is a
/// liveness probe and a transcript reader.
library;

import 'package:flutter/material.dart';

import '../client/hub_client_view.dart';
import 'session_menu.dart';

/// The transcript menu's thinking-level and model actions.
class ModelActions {
  ModelActions({
    required this.client,
    required this.isMounted,
    required this.transcriptOf,
  });

  final HubClientView client;

  /// Whether the owning State is still mounted. Read at each guard point, at
  /// the position the shell's own `mounted` checks held.
  final bool Function() isMounted;

  /// The transcript for a session id, or a blank one. Read at each use, at the
  /// position the shell read `_state.transcripts[id]`.
  final SessionTranscript Function(String) transcriptOf;

  /// Sends the picked thinking level. No optimistic update: the shown value
  /// comes from the next `usage` event, so an unsupported level snaps back to
  /// the clamped one pi actually applied.
  Future<void> setThinkingLevel(String activeId, BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final transcript = transcriptOf(activeId);
    final level = await pickThinkingLevel(context, transcript.thinkingLevel);
    if (!isMounted() || level == null) return;
    final result = await client.sendCommand(
      activeId,
      'setThinkingLevel',
      args: {'level': level},
    );
    if (!isMounted() || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not set the thinking level')),
    );
  }

  /// Lists pi's models and sends the picked one. No optimistic update: the
  /// shown name comes from the next `usage` event, so it cannot disagree with
  /// what pi actually applied.
  Future<void> setModel(String activeId, BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final listed = await client.listModels(activeId);
    // `context.mounted`, not the State's `mounted`: the picker below needs this
    // descendant context alive, and that is the check the analyzer requires.
    if (!context.mounted) return;
    if (!listed.ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(listed.error ?? 'could not list models')),
      );
      return;
    }
    final models = listed.models ?? const <ModelSummary>[];
    if (models.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No models available')),
      );
      return;
    }
    final transcript = transcriptOf(activeId);
    final picked = await pickModel(context, models, transcript.currentModel);
    if (!isMounted() || picked == null) return;
    final result = await client.sendCommand(
      activeId,
      'setModel',
      args: {'provider': picked.provider, 'id': picked.id},
    );
    if (!isMounted() || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not switch the model')),
    );
  }
}
