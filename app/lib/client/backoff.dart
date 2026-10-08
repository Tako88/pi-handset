/// Reconnect backoff: exponential with full jitter, capped.
///
/// Mirrors `pc/src/bridge/backoff.ts`: the app and the hub-side bridge compute
/// the same delay for the same attempt.
library;

import 'dart:math';

const int _baseMs = 500;
const int _capMs = 30000;

/// Exponential backoff with full jitter, capped. `attempt` is 0-based.
Duration computeBackoff(int attempt, {required double Function() rng}) {
  final exponent = attempt < 0 ? 0 : attempt;
  final ceilingMs = min(
    _capMs,
    (_baseMs * pow(2, exponent)).toInt(),
  );
  final delayMs = (rng() * ceilingMs).floor();
  return Duration(milliseconds: delayMs);
}
