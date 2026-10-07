// The pure notification policy: which settle notifications are *wanted*, per
// session, with a persisted mute override and an LRU cap. Flutter-free, so it
// tests without a binding.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/notification_policy.dart';
import 'package:pi_handset/client/settle_notification.dart';

void main() {
  group('shouldNotify', () {
    test('notifies for an engaged, unmuted session while backgrounded', () {
      final p = NotificationPolicy();
      expect(
        p.shouldNotify(
          presence: AppPresence.background,
          activeSessionId: 's1',
          sessionId: 's1',
          engaged: true,
          muted: false,
        ),
        isTrue,
      );
    });

    test('stays silent for a backgrounded session that was never engaged', () {
      final p = NotificationPolicy();
      expect(
        p.shouldNotify(
          presence: AppPresence.background,
          activeSessionId: 's1',
          sessionId: 's1',
          engaged: false,
          muted: false,
        ),
        isFalse,
      );
    });

    test('stays silent for a backgrounded session that is muted', () {
      final p = NotificationPolicy();
      expect(
        p.shouldNotify(
          presence: AppPresence.background,
          activeSessionId: 's1',
          sessionId: 's1',
          engaged: true,
          muted: true,
        ),
        isFalse,
      );
    });

    test('suppresses the session already on screen', () {
      final p = NotificationPolicy();
      expect(
        p.shouldNotify(
          presence: AppPresence.foreground,
          activeSessionId: 's1',
          sessionId: 's1',
          engaged: true,
          muted: false,
        ),
        isFalse,
      );
    });

    test('notifies an engaged session while foregrounded on the list', () {
      final p = NotificationPolicy();
      expect(
        p.shouldNotify(
          presence: AppPresence.foreground,
          activeSessionId: null,
          sessionId: 's1',
          engaged: true,
          muted: false,
        ),
        isTrue,
      );
    });

    test('stays silent for a never-engaged session on the list', () {
      final p = NotificationPolicy();
      expect(
        p.shouldNotify(
          presence: AppPresence.foreground,
          activeSessionId: null,
          sessionId: 's1',
          engaged: false,
          muted: false,
        ),
        isFalse,
      );
    });
  });

  group('encode/decode', () {
    test('round-trips engaged and muted', () {
      final p = NotificationPolicy(now: () => 1000)
        ..engage('s1')
        ..setMuted('s2', true);
      final back = NotificationPolicy.decode(p.encode());
      expect(back.isEngaged('s1'), isTrue);
      expect(back.isMuted('s1'), isFalse);
      expect(back.isEngaged('s2'), isFalse);
      expect(back.isMuted('s2'), isTrue);
    });

    test('decodes null and empty to an empty policy', () {
      expect(NotificationPolicy.decode(null).contains('s1'), isFalse);
      expect(NotificationPolicy.decode('').contains('s1'), isFalse);
      expect(NotificationPolicy.decode(null).encode(), '{"v":1,"entries":{}}');
      expect(NotificationPolicy.decode('').encode(), '{"v":1,"entries":{}}');
    });

    test('never throws and stays empty for malformed blobs', () {
      for (final blob in <String>[
        'not json',
        '[]',
        '{"v":2,"entries":{}}',
        '{"v":1,"entries":"x"}',
        '{"v":1,"entries":{"a":42}}',
        '{"v":1,"entries":{"":"x"}}',
      ]) {
        final p = NotificationPolicy.decode(blob);
        expect(p.contains('a'), isFalse, reason: blob);
        expect(p.encode(), '{"v":1,"entries":{}}', reason: blob);
      }
    });

    test('decodes a missing at as zero', () {
      final p = NotificationPolicy.decode(
        '{"v":1,"entries":{"a":{"engaged":true}}}',
      );
      expect(p.isEngaged('a'), isTrue);
      expect(p.isMuted('a'), isFalse);
      expect(p.encode(), contains('"at":0'));
    });
  });

  test('cap evicts the oldest entries beyond the limit', () {
    var t = 1000;
    final p = NotificationPolicy(now: () => t);
    for (var i = 0; i <= 104; i++) {
      p.engage('s$i');
      t++;
    }
    final back = NotificationPolicy.decode(p.encode());
    expect(back.contains('s104'), isTrue);
    expect(back.contains('s4'), isFalse);
    final entries = jsonDecode(back.encode())['entries'] as Map<String, dynamic>;
    expect(entries.length, notificationPolicyMaxEntries);
  });

  group('migrate', () {
    test('moves engaged and muted flags to the successor', () {
      final p = NotificationPolicy(now: () => 1000)
        ..engage('a1')
        ..setMuted('a1', true);
      final moved = p.migrate(from: 'a1', to: 'b1');
      expect(moved, isTrue);
      expect(p.isEngaged('b1'), isTrue);
      expect(p.isMuted('b1'), isTrue);
      expect(p.contains('a1'), isFalse);
    });

    test('refuses a self-migration and keeps the entry', () {
      final p = NotificationPolicy(now: () => 1000)..engage('a1');
      expect(p.migrate(from: 'a1', to: 'a1'), isFalse);
      expect(p.contains('a1'), isTrue);
      expect(p.isEngaged('a1'), isTrue);
    });

    test('returns false for an untracked predecessor and changes nothing', () {
      final p = NotificationPolicy(now: () => 1000)..engage('a1');
      expect(p.migrate(from: 'missing', to: 'b1'), isFalse);
      expect(p.contains('b1'), isFalse);
      expect(p.contains('a1'), isTrue);
    });

    test('ORs the flags into an already-tracked successor', () {
      final p = NotificationPolicy(now: () => 1000)
        ..engage('a1')
        ..setMuted('b1', true);
      p.migrate(from: 'a1', to: 'b1');
      expect(p.isEngaged('b1'), isTrue);
      expect(p.isMuted('b1'), isTrue);
    });
  });
}
