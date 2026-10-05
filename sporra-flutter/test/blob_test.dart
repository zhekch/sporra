import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/blob.dart';

void main() {
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
