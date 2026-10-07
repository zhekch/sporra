import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/blob.dart';

void main() {
  test('account snapshots clip ordinary and date-line viewports locally', () {
    List<dynamic> row(String id, double lng, double lat) => [
      id,
      mercX(lng < 0 ? lng + 360 : lng),
      mercY(lat),
      '#60acff',
      false,
    ];
    final rows = [
      row('home', 8, 47),
      row('east', 179, 0),
      row('west', -179, 0),
      row('far', 0, 70),
    ];
    expect(cellsInBounds(rows, [7, 46, 9, 48]).map((r) => r[0]), ['home']);
    expect(cellsInBounds(rows, [170, -5, -170, 5]).map((r) => r[0]), [
      'east',
      'west',
    ]);
    expect(cellsInBounds(rows, [-180, -85, 180, 85]), rows);
  });
  test('alpha shaping matches every browser golden vector', () {
    final vectors =
        jsonDecode(File('test/blob-vectors.json').readAsStringSync()) as Map;
    for (final entry in vectors.entries) {
      expect(alphaCurve(double.parse(entry.key)), entry.value);
    }
  });
  test('camera ladder changes at the browser thresholds', () {
    expect(levelForZoom(13.6), 0);
    expect(levelForZoom(13.59), 1);
    expect(levelForZoom(4.1), 6);
    expect(levelForZoom(2.75), 7);
    expect(levelForZoom(2.74), 8);
  });
  test('Mercator roundtrips around the antimeridian', () {
    for (final x in [-179.0, 0.0, 179.0]) {
      expect(longitude(mercX(x)), closeTo(x, 1e-9));
    }
    expect(latitude(mercY(47)), closeTo(47, 1e-9));
  });
}
