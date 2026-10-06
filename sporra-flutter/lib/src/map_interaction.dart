import 'dart:math' as math;

import 'blob.dart';

final regionFineZoom = 13.6 - 6 * math.log(3) / math.ln2;
const routeTapPadding = 8.0;
const trackColor = '#ffcf4d';
// Geometry only; visit aggregation stays in the shared server rollup.
String cellKey(int level, double lng, double lat) {
  final columns = (625482 / math.pow(3, level)).round();
  final radius = world / columns / 1.5;
  final x = mercX(lng), y = mercY(lat);
  final qf = 2 / 3 * x / radius;
  final rf = (-x / 3 + math.sqrt(3) / 3 * y) / radius;
  // Match JavaScript's rounding of negative half values.
  var q = (qf + 0.5).floor(), r = (rf + 0.5).floor();
  final s = (-qf - rf + 0.5).floor();
  final dq = (q - qf).abs(), dr = (r - rf).abs(), ds = (s + qf + rf).abs();
  if (dq > dr && dq > ds) {
    q = -s - r;
  } else if (dr > ds) {
    r = -q - s;
  }
  final row = r + (q - (q & 1)) ~/ 2;
  return '${q % columns}/$row';
}

List<dynamic> routeWidth({dynamic selectedId, double scale = 1}) {
  dynamic width(double value) => selectedId == null
      ? value * scale
      : [
          'case',
          [
            '==',
            ['get', 'id'],
            selectedId,
          ],
          value * scale * 1.7,
          value * scale,
        ];
  return [
    'interpolate',
    ['linear'],
    ['zoom'],
    3,
    width(0.9),
    10,
    width(2),
    16,
    width(3.4),
  ];
}

List<dynamic> metricWidth({double scale = 1}) => [
  'interpolate',
  ['linear'],
  ['zoom'],
  3,
  0.9 * 1.7 * scale,
  10,
  2 * 1.7 * scale,
  16,
  3.4 * 1.7 * scale,
];
