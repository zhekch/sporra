import 'dart:convert';

import 'package:flutter/foundation.dart';

const performanceTraceEnabled = bool.fromEnvironment(
  'SPORRA_PERFORMANCE_TRACE',
);

// Diagnostics contain durations/counts only; never account names, request
// queries, coordinates, tokens, or response payloads.
void tracePerformance(
  String stage,
  Stopwatch clock, [
  Map<String, num> counts = const {},
]) {
  if (performanceTraceEnabled) {
    debugPrint(
      'SPORRA_PERFORMANCE ${jsonEncode({'stage': stage, 'ms': clock.elapsedMilliseconds, ...counts})}',
    );
  }
}
