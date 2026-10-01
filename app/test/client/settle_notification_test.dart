// The pure notification rules: when to notify, what the body says, and the
// stable per-session id. Flutter-free, so it tests without a binding.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/settle_notification.dart';

void main() {
  group('shouldNotifyOnSettle', () {
    test('suppresses a settle for the session already on screen', () {
      expect(
        shouldNotifyOnSettle(AppPresence.foreground, 's1', 's1'),
        isFalse,
      );
    });

    test('notifies for a different session while foreground', () {
      expect(shouldNotifyOnSettle(AppPresence.foreground, 's1', 's2'), isTrue);
    });

    test('notifies for any session while backgrounded', () {
      expect(shouldNotifyOnSettle(AppPresence.background, 's1', 's1'), isTrue);
      expect(shouldNotifyOnSettle(AppPresence.background, 's2', 's1'), isTrue);
    });

    test('notifies when the session list is shown', () {
      expect(shouldNotifyOnSettle(AppPresence.foreground, null, 's1'), isTrue);
    });
  });

  group('notificationBody', () {
    test('collapses whitespace and trims', () {
      expect(notificationBody('  hello \n\t world  '), 'hello world');
    });

    test('falls back when there is nothing to show', () {
      expect(notificationBody('   \n  '), notificationFallbackBody);
    });

    test('keeps exactly maxLength code points without an ellipsis', () {
      final text = 'x' * notificationBodyMaxCodePoints;
      expect(notificationBody(text), text);
    });

    test('truncates one code point over with an ellipsis', () {
      final text = 'x' * (notificationBodyMaxCodePoints + 1);
      expect(notificationBody(text), '${'x' * notificationBodyMaxCodePoints}…');
    });

    test('marks a bridge truncation even when the text is short', () {
      expect(notificationBody('short', truncated: true), 'short…');
    });
  });

  group('notificationIdForSession', () {
    test('is deterministic', () {
      expect(
        notificationIdForSession('s1'),
        notificationIdForSession('s1'),
      );
    });

    test('never collides with the persistent foreground-service id', () {
      for (final sessionId in ['s1', 's2', 'a1', '', 'a very long session id']) {
        final id = notificationIdForSession(sessionId);
        expect(id, greaterThanOrEqualTo(1000));
        expect(id, isNot(1));
      }
    });
  });
}
