/// The single writer of the mutable state the hub client owns.
///
/// Pure Dart: the state snapshot, the connection-scoped error flag, the
/// per-session transcript derivations and counters, and the restore flags all
/// live here, so each has exactly one owner. Every mutation the client and its
/// collaborators make goes through a method on this class; this file is the
/// only place the snapshot field is declared or assigned.
library;

import 'hub_models.dart';
import 'transcript.dart';

/// The state the hub client owns: the state snapshot, the connection-scoped
/// error flag, the per-session derivations and counters, and the restore
/// flags. Extracted from the hub client so the state has a single writer.
class SessionStateStore {
  HubClientState _state = const HubClientState();

  /// Whether the current [state]'s error came from the connection path (dial,
  /// auth, send) rather than a session/operation. A later authenticated
  /// connection clears the former; it never clears the latter, because a
  /// reconnect does not fix a session that is gone or a token that would not
  /// persist.
  bool _lastErrorFromConnection = false;

  /// One incremental derivation per live session, put and removed in lockstep
  /// with [state]'s `transcripts`. See [withEntries] for the staleness
  /// contract.
  final Map<String, TranscriptDerivation> _derivations = {};

  /// Consecutive resync answers per session, reset by a `snapshot` or a fresh
  /// `subscribe`.
  final Map<String, int> _resyncCounts = {};

  /// Consecutive `session-gone` answers per session, reset by a `snapshot`, a
  /// user-initiated `subscribe`, or `disconnect`.
  final Map<String, int> _sessionGoneCounts = {};

  /// Sessions whose current subscription was restored automatically after a
  /// reconnect, rather than chosen by the user. A `session-gone` answering one
  /// of these is the re-subscribe racing the agent's re-registration, not a
  /// deletion, so its transcript is kept until the give-up cap.
  final Set<String> _restoredSessions = {};

  /// The session the user last asked to view. Unlike the state's
  /// `activeSessionId` it survives a `session-gone`, so a re-subscribe that
  /// raced the agent's re-registration after a hub restart can be retried when
  /// the session reappears instead of leaving the client silently
  /// unsubscribed.
  String? _desiredSessionId;

  bool _resubscribed = false;

  /// The current snapshot.
  HubClientState get state => _state;

  /// Replaces [state] with [f]'s result. The only assignment to the snapshot.
  void update(HubClientState Function(HubClientState) f) {
    _state = f(_state);
  }

  /// Whether [state]'s error came from the connection path rather than a
  /// session/operation.
  bool get lastErrorFromConnection => _lastErrorFromConnection;

  /// Records a user-visible error and whether a later authenticated connection
  /// supersedes it. Dial, auth and send failures are connection-scoped; session
  /// and operation notices are not.
  void setError(String message, {required bool connection}) {
    _lastErrorFromConnection = connection;
    _state = _state.copyWith(lastError: message);
  }

  /// Clears a connection-scoped error, leaving a session/operation notice where
  /// it is: a new dial does not fix a session that is gone or a token that would
  /// not persist. Returns true iff it cleared the flag.
  bool clearConnectionError() {
    if (!_lastErrorFromConnection) return false;
    _lastErrorFromConnection = false;
    _state = _state.copyWith(lastError: null);
    return true;
  }

  SessionTranscript? transcript(String sessionId) =>
      _state.transcripts[sessionId];

  void ensureTranscript(String sessionId) {
    if (_state.transcripts.containsKey(sessionId)) return;
    putTranscript(sessionId, const SessionTranscript());
  }

  void putTranscript(String sessionId, SessionTranscript transcript) {
    _state = _state.copyWith(
      transcripts: {..._state.transcripts, sessionId: transcript},
    );
  }

  /// Extends [transcript]'s session by [entry] through that session's
  /// derivation instead of re-deriving the whole list. Returns a transcript
  /// holding *copies* of the derivation's lists, so a retained old transcript
  /// can never observe a later append. `transcript.entries` is consulted only
  /// when the derivation is missing or does not match the incoming baseline.
  SessionTranscript withEntries(
    String sessionId,
    SessionTranscript transcript,
    Object? entry,
  ) {
    var derivation = _derivations[sessionId];
    if (derivation == null ||
        !_matchesDerivation(derivation, transcript.entries)) {
      derivation = TranscriptDerivation()..rebuild(transcript.entries);
      _derivations[sessionId] = derivation;
    }
    derivation.append(entry);
    return transcript.copyWith(
      entries: List<Object?>.of(derivation.entries),
      blocks: List<TranscriptBlock>.of(derivation.blocks),
    );
  }

  /// Cheap staleness net. Under design D the transcript always holds a fresh
  /// copy, so `identical(entries)` is useless; the copy preserves element
  /// *objects*, so tail identity plus length detects a replaced baseline. The
  /// primary mechanism is explicit invalidation at every replacement point
  /// (snapshot, the `session-gone` drop branch, `disconnect`, `stop`); this
  /// catches a path that did not. It cannot see a same-length, same-tail
  /// interior change — no current path produces one, and any future one must
  /// invalidate explicitly.
  bool _matchesDerivation(TranscriptDerivation d, List<Object?> entries) {
    if (d.entries.length != entries.length) return false;
    if (entries.isEmpty) return true;
    return identical(d.entries.last, entries.last);
  }

  TranscriptDerivation? derivation(String sessionId) => _derivations[sessionId];

  void setDerivation(String sessionId, TranscriptDerivation derivation) {
    _derivations[sessionId] = derivation;
  }

  void removeDerivation(String sessionId) => _derivations.remove(sessionId);

  void clearDerivations() => _derivations.clear();

  int resyncCount(String sessionId) => _resyncCounts[sessionId] ?? 0;

  void setResyncCount(String sessionId, int count) {
    _resyncCounts[sessionId] = count;
  }

  void removeResyncCount(String sessionId) => _resyncCounts.remove(sessionId);

  int goneCount(String sessionId) => _sessionGoneCounts[sessionId] ?? 0;

  void setGoneCount(String sessionId, int count) {
    _sessionGoneCounts[sessionId] = count;
  }

  void removeGoneCount(String sessionId) => _sessionGoneCounts.remove(sessionId);

  bool isRestored(String sessionId) => _restoredSessions.contains(sessionId);

  void setRestored(String sessionId, bool value) {
    if (value) {
      _restoredSessions.add(sessionId);
    } else {
      _restoredSessions.remove(sessionId);
    }
  }

  void removeRestored(String sessionId) => _restoredSessions.remove(sessionId);

  // The accessor pair is deliberate — the private field stays the store's own —
  // so the wrapper is not redundant here.
  // ignore: unnecessary_getters_setters
  String? get desiredSessionId => _desiredSessionId;

  set desiredSessionId(String? value) => _desiredSessionId = value;

  // ignore: unnecessary_getters_setters
  bool get resubscribed => _resubscribed;

  set resubscribed(bool value) => _resubscribed = value;

  /// Resets to the initial snapshot and clears every map and flag above. Called
  /// by `disconnect`, which leaves the client reusable for a new hub.
  void resetForDisconnect() {
    _resubscribed = false;
    _desiredSessionId = null;
    _resyncCounts.clear();
    _sessionGoneCounts.clear();
    _restoredSessions.clear();
    _derivations.clear();
    _lastErrorFromConnection = false;
    _state = const HubClientState();
  }
}
