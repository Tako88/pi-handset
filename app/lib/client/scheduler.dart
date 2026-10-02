/// The injected scheduler: reconnect waits, frame coalescing, the auth
/// watchdog and per-command timeouts all go through it, so tests are
/// deterministic and never sleep.
library;

import 'dart:async';

/// What a scheduled timer is for. The production scheduler ignores this; it
/// exists so the test scheduler can fire one kind of timer without tripping
/// the others.
enum HubTimerKind { notify, reconnect, auth, command, connect, replacement }

abstract class HubTimer {
  void cancel();
}

abstract class HubScheduler {
  /// Runs [task] after [delay]; returns a handle the client can cancel.
  ///
  /// [kind] labels the timer so a fake scheduler can fire it deterministically.
  HubTimer schedule(
    Duration delay,
    void Function() task, {
    HubTimerKind kind = HubTimerKind.notify,
  });
}

/// Production scheduler, backed by `dart:async`'s [Timer].
class TimerHubScheduler implements HubScheduler {
  @override
  HubTimer schedule(
    Duration delay,
    void Function() task, {
    HubTimerKind kind = HubTimerKind.notify,
  }) => TimerHubTimer(Timer(delay, task));
}

class TimerHubTimer implements HubTimer {
  TimerHubTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}
