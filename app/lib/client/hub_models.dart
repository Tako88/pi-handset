/// The hub client's value types — the plain data the client holds and the UI
/// renders.
///
/// Pure Dart: no Flutter import, so it tests without a widget binding. These
/// types are re-exported from `hub_client.dart`, so every existing importer
/// keeps resolving them.
library;

import 'context_usage.dart';
import 'transcript.dart';

/// Where the connection is in its lifecycle.
enum HubConnectionStatus { disconnected, connecting, authenticating, connected }

/// One entry in the hub's `sessions` push. Deliberately no `lastSeq`.
class SessionSummary {
  final String sessionId;
  final String label;
  final String agentState;

  /// The session id this session replaces, when pi started it with `/new` or
  /// `/fork`. Absent for an ordinary registration and for a hub that predates
  /// the field. The app keys its replacement follow on this, never on the
  /// command ack.
  final String? replacesSessionId;

  /// Who started the session: `'app'` (the hub spawned it) or `'pc'`. Defaults
  /// to `'pc'` so a hub that predates the field never strands a viewer.
  final String origin;

  const SessionSummary({
    required this.sessionId,
    required this.label,
    required this.agentState,
    this.replacesSessionId,
    this.origin = 'pc',
  });

  factory SessionSummary.fromJson(Map<String, Object?> json) => SessionSummary(
    sessionId: json['sessionId']! as String,
    label: json['label']! as String,
    agentState: json['agentState']! as String,
    replacesSessionId: json['replacesSessionId'] as String?,
    origin: json['origin'] as String? ?? 'pc',
  );
}

/// One `agent-settled` broadcast: a session settled and the app may notify.
/// Viewer-scoped rather than subscriber-scoped, so it may name a session the
/// client is not viewing. Carries the bridge's snippet and its truncation flag.
class AgentSettledEvent {
  final String sessionId;
  final String label;
  final String text;
  final bool truncated;

  const AgentSettledEvent({
    required this.sessionId,
    required this.label,
    required this.text,
    required this.truncated,
  });
}

/// One `leaf` event: the bridge moved a session's leaf, or pi did on the PC.
/// Carries the session it is attributed to (relay frames name none, so the
/// client uses the active one) and the new leaf id, which is `null` when the
/// leaf moved to the root. A signal, not a transcript row.
class LeafEvent {
  final String sessionId;
  final String? leafId;

  const LeafEvent({required this.sessionId, required this.leafId});
}

/// The renderer-agnostic transcript for one session.
///
/// [entries] hold raw relayed values exactly as they arrived (history/snapshot
/// entries, relayed `message` bodies, and raw `status`/`tool` payloads), so the
/// UI layer can decide how to render them. Markdown, if it is ever rendered, is
/// a UI decision this type does not make.
class SessionTranscript {
  final List<Object?> entries;

  /// The ordered display blocks derived from [entries]. Recomputed only when
  /// entries change — never per stream delta.
  final List<TranscriptBlock> blocks;

  /// Text accumulated from `stream` deltas since the last baseline.
  final String streamingText;

  /// Reasoning accumulated from `phase: 'thinking'` stream deltas since the last
  /// baseline. Kept separate from [streamingText] so a reasoning chunk can never
  /// be mistaken for the reply. Only the committed assistant message retires it
  /// mid-turn — a settle, an error status or a snapshot also clears it as
  /// teardown, exactly as they clear the reply buffer.
  final String streamingThinking;

  /// True while deltas are being appended; cleared on `agent_settled` (the
  /// protocol's terminal state), never on a message-level completion.
  final bool streaming;

  /// True while the bridge has signalled the thinking phase and no text has
  /// streamed yet. Set by a content-free `stream` phase frame.
  final bool thinking;

  final String agentState;
  final int lastSeq;
  final bool historyLoaded;
  final bool truncated;

  /// The model's context usage for this session, or null while the bridge has
  /// not reported one. Ambient state rather than a transcript row: it is
  /// rendered in the app bar, never in the message list.
  final ContextUsage? contextUsage;

  /// The thinking level pi reports as active for this session, or null while
  /// the bridge has not reported one (an older bridge omits the field). The
  /// menu displays it; it is never a transcript row.
  final String? thinkingLevel;

  /// The model pi reports as active for this session, or null while the bridge
  /// has not reported one (an older bridge omits the field). The menu displays
  /// its name; it is never a transcript row.
  final ModelSummary? currentModel;

  /// True while pi is compacting this session's context. Ambient state, like
  /// [contextUsage]: the app bar shows it in place of the context reading,
  /// which is exactly what compaction is about to change.
  final bool compacting;

  /// The opaque cursor for the next older page, or null when this transcript is
  /// already at the beginning of the session (or the bridge does not page).
  final String? olderCursor;

  /// True while an older-page request is in flight for this session. Disables
  /// the load-older control without discarding the cursor it resumes from.
  final bool historyLoading;

  const SessionTranscript({
    this.entries = const [],
    this.blocks = const [],
    this.streamingText = '',
    this.streamingThinking = '',
    this.streaming = false,
    this.thinking = false,
    this.agentState = 'idle',
    this.lastSeq = 0,
    this.historyLoaded = false,
    this.truncated = false,
    this.contextUsage,
    this.thinkingLevel,
    this.currentModel,
    this.compacting = false,
    this.olderCursor,
    this.historyLoading = false,
  });

  SessionTranscript copyWith({
    List<Object?>? entries,
    List<TranscriptBlock>? blocks,
    String? streamingText,
    String? streamingThinking,
    bool? streaming,
    bool? thinking,
    String? agentState,
    int? lastSeq,
    bool? historyLoaded,
    bool? truncated,
    ContextUsage? contextUsage,
    String? thinkingLevel,
    ModelSummary? currentModel,
    bool? compacting,
    Object? olderCursor = _unset,
    bool? historyLoading,
  }) => SessionTranscript(
    entries: entries ?? this.entries,
    blocks: blocks ?? this.blocks,
    streamingText: streamingText ?? this.streamingText,
    streamingThinking: streamingThinking ?? this.streamingThinking,
    streaming: streaming ?? this.streaming,
    thinking: thinking ?? this.thinking,
    agentState: agentState ?? this.agentState,
    lastSeq: lastSeq ?? this.lastSeq,
    historyLoaded: historyLoaded ?? this.historyLoaded,
    truncated: truncated ?? this.truncated,
    contextUsage: contextUsage ?? this.contextUsage,
    thinkingLevel: thinkingLevel ?? this.thinkingLevel,
    currentModel: currentModel ?? this.currentModel,
    compacting: compacting ?? this.compacting,
    // A page reaching the session's beginning clears the cursor, so it must be
    // settable to null: an `??` default could only ever keep the old value.
    olderCursor: identical(olderCursor, _unset)
        ? this.olderCursor
        : olderCursor as String?,
    historyLoading: historyLoading ?? this.historyLoading,
  );
}

const Object _unset = Object();

/// An immutable snapshot of everything the client knows.
class HubClientState {
  final HubConnectionStatus status;
  final List<SessionSummary> sessions;
  final Map<String, SessionTranscript> transcripts;
  final String? activeSessionId;
  final String? lastError;

  /// The hub's advertised capabilities, read from the post-auth `sessions`
  /// frame. Empty for a hub that predates the field, which hides folder
  /// browsing and its `start-session{cwd}` form rather than sending a frame an
  /// old hub would answer with a terminal `4003` close.
  final Set<String> capabilities;

  /// The per-session real pi commands, fetched on session open and
  /// re-fetched on reconnect-restore, keyed by session id. A session never
  /// fetched from (or one whose hub refused the list) simply has no key.
  final Map<String, List<SlashCommand>> commands;

  const HubClientState({
    this.status = HubConnectionStatus.disconnected,
    this.sessions = const [],
    this.transcripts = const {},
    this.activeSessionId,
    this.lastError,
    this.capabilities = const {},
    this.commands = const {},
  });

  HubClientState copyWith({
    HubConnectionStatus? status,
    List<SessionSummary>? sessions,
    Map<String, SessionTranscript>? transcripts,
    Object? activeSessionId = _unset,
    Object? lastError = _unset,
    Set<String>? capabilities,
    Map<String, List<SlashCommand>>? commands,
  }) => HubClientState(
    status: status ?? this.status,
    sessions: sessions ?? this.sessions,
    transcripts: transcripts ?? this.transcripts,
    capabilities: capabilities ?? this.capabilities,
    commands: commands ?? this.commands,
    activeSessionId: identical(activeSessionId, _unset)
        ? this.activeSessionId
        : activeSessionId as String?,
    lastError: identical(lastError, _unset)
        ? this.lastError
        : lastError as String?,
  );
}

/// The outcome of one dispatched command.
class CommandResult {
  final bool ok;
  final String? error;

  /// Present only on a `listCommands` result.
  final List<SlashCommand>? commands;

  /// Present only on a `listModels` result.
  final List<ModelSummary>? models;

  /// Tri-state: absent (`null`) = the bridge did not queue this (unknown /
  /// not-queued); `true` = accepted and dispatched as a mid-turn `steer`;
  /// `false` = never sent. The bridge only ever emits `true` or omits the key.
  final bool? queued;

  /// Present only on a `listTree` result.
  final List<TreeNodeSummary>? tree;

  /// Present only on a `listTree` result: whether older nodes were dropped.
  final bool? treeTruncated;

  /// Present only on a `listTree` result: the current leaf id, or `null` when
  /// pi has no leaf. An older bridge omits the field entirely, which also reads
  /// as `null` — an unknown position, never an error.
  final String? leafId;

  const CommandResult({
    required this.ok,
    this.error,
    this.commands,
    this.models,
    this.queued,
    this.tree,
    this.treeTruncated,
    this.leafId,
  });
}

/// One session-tree node as it crosses the wire: a user or assistant message
/// with the nearest *emitted* ancestor's id, so the app can indent without
/// knowing pi's skipped entry variants.
class TreeNodeSummary {
  final String id;
  final String? parentId;
  final String role;
  final String? label;
  final String text;

  const TreeNodeSummary({
    required this.id,
    required this.parentId,
    required this.role,
    required this.text,
    this.label,
  });

  factory TreeNodeSummary.fromJson(Map<String, Object?> json) =>
      TreeNodeSummary(
        id: json['id']! as String,
        parentId: json['parentId'] as String?,
        role: json['role']! as String,
        label: json['label'] as String?,
        text: json['text']! as String,
      );
}

/// One slash command pi offers for a session, as it crosses the wire: `name`
/// and an optional `description`. pi's `source`/`sourceInfo` are deliberately
/// dropped — the app renders a label and a subtitle only.
class SlashCommand {
  final String name;
  final String? description;

  const SlashCommand({required this.name, this.description});

  factory SlashCommand.fromJson(Map<String, Object?> json) => SlashCommand(
    name: json['name']! as String,
    description: json['description'] as String?,
  );
}

/// One of pi's auth-configured models, projected to the three fields the app
/// needs. The bridge deliberately drops `headers`, `baseUrl` and the rest.
class ModelSummary {
  final String provider;
  final String id;
  final String name;

  const ModelSummary({
    required this.provider,
    required this.id,
    required this.name,
  });

  factory ModelSummary.fromJson(Map<String, Object?> json) => ModelSummary(
    provider: json['provider']! as String,
    id: json['id']! as String,
    name: json['name']! as String,
  );
}

/// One directory listing: the resolved directory, the browse root, whether a
/// trust decision exists, whether the directory requires one, its entry names,
/// and whether the cap truncated the listing.
class DirListing {
  final String path;
  final String root;

  /// The nearest trust decision (`true`/`false`), or null when there is none.
  final bool? trust;

  final bool trustRequired;
  final List<String> entries;
  final bool truncated;

  const DirListing({
    required this.path,
    required this.root,
    required this.trust,
    required this.trustRequired,
    required this.entries,
    required this.truncated,
  });
}

/// The outcome of one `list-dirs`: the listing on success, or an error.
class DirListingResult {
  final bool ok;
  final String? error;
  final DirListing? listing;
  const DirListingResult({required this.ok, this.error, this.listing});
}
