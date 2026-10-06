import 'dart:math' as math;

import 'package:flutter/widgets.dart';

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

Map<String, dynamic> cellOutline(int level, double lng, double lat) {
  final columns = (625482 / math.pow(3, level)).round();
  final radius = world / columns / 1.5;
  final key = cellKey(level, lng, lat).split('/');
  var col = int.parse(key[0]);
  col += ((mercX(lng) / world) - col / columns).round() * columns;
  final row = int.parse(key[1]);
  final x = 1.5 * radius * col;
  final y = math.sqrt(3) * radius * (row + (col & 1) / 2);
  var points = [
    for (var i = 0; i < 6; i++)
      [
        x + radius * math.cos(i * math.pi / 3),
        y + radius * math.sin(i * math.pi / 3),
      ],
  ];
  for (var round = 0; round < 4; round++) {
    final next = <List<double>>[];
    for (var i = 0; i < points.length; i++) {
      final a = points[i], b = points[(i + 1) % points.length];
      for (final cut in [0.28, 0.72]) {
        next.add([a[0] + (b[0] - a[0]) * cut, a[1] + (b[1] - a[1]) * cut]);
      }
    }
    points = next;
  }
  final ring = [
    ...points,
    points.first,
  ].map((p) => [longitude(p[0]), latitude(p[1])]).toList();
  return {'type': 'LineString', 'coordinates': ring};
}

String groupedNumber(num value) => value.round().toString().replaceAllMapped(
  RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
  (match) => '${match[1]},',
);

String formatGround(num value) =>
    '${value >= 1000
        ? groupedNumber(value)
        : value >= 10
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1)} km²';
String formatPercent(num value) => value >= 1
    ? '${value.toStringAsFixed(0)}%'
    : value >= 0.1
    ? '${value.toStringAsFixed(1)}%'
    : value >= 0.005
    ? '${value.toStringAsFixed(2)}%'
    : '<0.01%';

// Compare directed longitude intervals, including views crossing the date line.
bool viewportWithin(
  List<double> outer,
  List<double> inner, {
  double inset = 0,
}) {
  final latMargin = (outer[3] - outer[1]) * inset;
  if (inner[1] < outer[1] + latMargin || inner[3] > outer[3] - latMargin) {
    return false;
  }
  double span(List<double> b) => b[2] - b[0] == 360 ? 360 : (b[2] - b[0]) % 360;
  final available = span(outer);
  final offset = (inner[0] - outer[0]) % 360;
  final lngMargin = available * inset;
  return available == 360 ||
      (offset >= lngMargin && offset + span(inner) <= available - lngMargin);
}

EdgeInsets activityMapPadding(Size viewport, Size card, EdgeInsets safeArea) {
  const gap = 24.0;
  return viewport.width < 600
      ? EdgeInsets.fromLTRB(
          safeArea.left + gap,
          safeArea.top + 80,
          safeArea.right + gap,
          safeArea.bottom + 10 + card.height + gap,
        )
      : EdgeInsets.fromLTRB(
          safeArea.left + 10 + card.width + gap,
          safeArea.top + 80,
          safeArea.right + gap,
          safeArea.bottom + gap,
        );
}
