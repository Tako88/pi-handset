/// The pure notification policy: which sessions the user has *engaged* (opened,
/// or started from the app), plus a persisted per-session mute override and an
/// LRU cap on tracked entries.
///
/// Deliberately Flutter-free, so it is unit-testable without a binding and
/// lives beside the rest of the client's pure logic. The presence decision
/// itself is delegated, unchanged, to [shouldNotifyOnSettle].
///
/// The app shell resolves engagement (it alone knows the session origin) and
/// passes the resulting bool in; this module only stores and reports it.
library;

import 'dart:convert';

import 'settle_notification.dart';

/// The most tracked sessions the policy will keep. Beyond this, the oldest
/// (by last touch, ties broken by id) are evicted.
const int notificationPolicyMaxEntries = 100;

/// One tracked session: whether it is engaged, whether it is muted, and when it
/// was last touched (for the LRU cap).
class _Entry {
  _Entry({required this.engaged, required this.muted, required this.at});

  bool engaged;
  bool muted;
  int at;
}

/// The persisted engagement/mute policy. Decode contract: [decode] never throws
/// for any input — a corrupt blob yields an empty policy, never a crash.
class NotificationPolicy {
  NotificationPolicy({int Function()? now})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Restores a policy from [blob], or an empty one for any unreadable input.
  factory NotificationPolicy.decode(String? blob, {int Function()? now}) {
    final policy = NotificationPolicy(now: now);
    if (blob == null || blob.isEmpty) return policy;
    try {
      final raw = jsonDecode(blob);
      if (raw is! Map) return policy;
      if (raw['v'] != 1) return policy;
      final entries = raw['entries'];
      if (entries is! Map) return policy;
      entries.forEach((key, value) {
        if (key is! String || key.isEmpty) return;
        if (value is! Map) return;
        final engaged = value['engaged'];
        final muted = value['muted'];
        final at = value['at'];
        policy._entries[key] = _Entry(
          engaged: engaged is bool ? engaged : false,
          muted: muted is bool ? muted : false,
          at: at is int ? at : 0,
        );
      });
    } catch (_) {
      return NotificationPolicy(now: now);
    }
    policy._prune();
    return policy;
  }

  final int Function() _now;
  final Map<String, _Entry> _entries = {};

  /// Whether [sessionId] was engaged (opened, or started from the app).
  bool isEngaged(String sessionId) => _entries[sessionId]?.engaged ?? false;

  /// Whether [sessionId] is muted.
  bool isMuted(String sessionId) => _entries[sessionId]?.muted ?? false;

  /// Whether [sessionId] has a tracked entry at all.
  bool contains(String sessionId) => _entries.containsKey(sessionId);

  /// Marks [sessionId] engaged and touched now.
  void engage(String sessionId) {
    final entry = _entries[sessionId];
    if (entry == null) {
      _entries[sessionId] = _Entry(engaged: true, muted: false, at: _now());
    } else {
      entry.engaged = true;
      entry.at = _now();
    }
    _prune();
  }

  /// Sets the mute override for [sessionId] and touches it now.
  void setMuted(String sessionId, bool muted) {
    final entry = _entries[sessionId];
    if (entry == null) {
      _entries[sessionId] = _Entry(engaged: false, muted: muted, at: _now());
    } else {
      entry.muted = muted;
      entry.at = _now();
    }
    _prune();
  }

  /// Moves [from]'s flags onto [to] (a `/new`//`/fork` successor). Returns true
  /// when [from] was tracked. Flags are OR'd into an already-tracked [to].
  bool migrate({required String from, required String to}) {
    if (from == to) return false;
    final source = _entries[from];
    if (source == null) return false;
    final target = _entries[to];
    if (target == null) {
      _entries[to] = _Entry(
        engaged: source.engaged,
        muted: source.muted,
        at: source.at,
      );
    } else {
      target.engaged = target.engaged || source.engaged;
      target.muted = target.muted || source.muted;
      target.at = _now();
    }
    _entries.remove(from);
    _prune();
    return true;
  }

  /// Whether a settle for [sessionId] should notify, given the resolved
  /// [engaged]/[muted] flags and the current [presence]. An unmuted engaged
  /// session defers to [shouldNotifyOnSettle], whose rule is unchanged.
  bool shouldNotify({
    required AppPresence presence,
    required String? activeSessionId,
    required String sessionId,
    required bool engaged,
    required bool muted,
  }) {
    if (muted) return false;
    if (!engaged) return false;
    return shouldNotifyOnSettle(presence, activeSessionId, sessionId);
  }

  /// Serialises the policy to its persisted form.
  String encode() {
    final entries = <String, Object?>{};
    for (final entry in _entries.entries) {
      entries[entry.key] = {
        'engaged': entry.value.engaged,
        'muted': entry.value.muted,
        'at': entry.value.at,
      };
    }
    return jsonEncode({'v': 1, 'entries': entries});
  }

  /// Drops the least-recently-touched entries until the cap holds; ties are
  /// broken by key so eviction is deterministic.
  void _prune() {
    if (_entries.length <= notificationPolicyMaxEntries) return;
    final keys = _entries.keys.toList()
      ..sort((a, b) {
        final byAt = _entries[a]!.at.compareTo(_entries[b]!.at);
        return byAt != 0 ? byAt : a.compareTo(b);
      });
    final drop = _entries.length - notificationPolicyMaxEntries;
    for (var i = 0; i < drop; i++) {
      _entries.remove(keys[i]);
    }
  }
}
