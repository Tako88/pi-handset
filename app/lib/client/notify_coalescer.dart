// ignore_for_file: prefer_initializing_formals
// The dependency fields are private, and a private *named* parameter is illegal
// in Dart, so the initializer list is the only way to bind them (the lint's
// suggested fix does not compile).

/// Coalesces state notifications: at most one emit per scheduled frame.
///
/// Extracted from the hub client so the timer handle and the coalescing
/// decision have a single owner. The emit callback is the caller's, so the
/// changes controller's `isClosed` guard stays with the client.
library;

import 'hub_models.dart';
import 'scheduler.dart';

/// Fires at most one notification per scheduled frame, however many deltas
/// arrive in between.
class NotifyCoalescer {
  NotifyCoalescer({
    required HubScheduler scheduler,
    required Duration interval,
    required HubClientState Function() current,
    required void Function(HubClientState) emit,
  }) : _scheduler = scheduler,
       _interval = interval,
       _current = current,
       _emit = emit;

  final HubScheduler _scheduler;
  final Duration _interval;
  final HubClientState Function() _current;
  final void Function(HubClientState) _emit;

  HubTimer? _timer;

  /// Arms the coalescing timer, unless one is already armed. When it fires the
  /// current state is read once and emitted.
  void schedule() {
    if (_timer != null) return;
    _timer = _scheduler.schedule(_interval, () {
      _timer = null;
      _emit(_current());
    }, kind: HubTimerKind.notify);
  }

  /// Emits the current state immediately, cancelling any coalescing wait. Used
  /// where a terminal state must be observed before the stream closes.
  void flush() {
    _timer?.cancel();
    _timer = null;
    _emit(_current());
  }
}
