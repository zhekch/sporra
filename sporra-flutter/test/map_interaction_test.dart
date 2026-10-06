import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:sporra_flutter/src/map_interaction.dart';
import 'package:sporra_flutter/src/blob.dart'
    show mercX, mercY, longitude, latitude;

void main() {
  test(
    'activity camera fit excludes the measured card and phone safe area',
    () {
      final padding = activityMapPadding(
        const Size(390, 844),
        const Size(370, 300),
        const EdgeInsets.fromLTRB(0, 59, 0, 34),
      );
      expect(padding.bottom, 368);
      expect(padding.top, 139);
      final larger = activityMapPadding(
        const Size(390, 844),
        const Size(370, 430),
        const EdgeInsets.fromLTRB(0, 59, 0, 34),
      );
      expect(larger.bottom - padding.bottom, 130);
      final wide = activityMapPadding(
        const Size(1024, 768),
        const Size(440, 300),
        EdgeInsets.zero,
      );
      expect(wide.left, 474);
      expect(wide.bottom, 24);
    },
  );

  test('padded viewport reuse respects edges and the date line', () {
    expect(
      viewportWithin([-20, -10, 20, 10], [-19, -5, 10, 5], inset: 0.1),
      isFalse,
    );
    expect(
      viewportWithin([170, -10, -170, 10], [175, -5, -175, 5], inset: 0.1),
      isTrue,
    );
    expect(viewportWithin([-20, -10, 20, 10], [-10, -5, 10, 5]), isTrue);
    expect(viewportWithin([-20, -10, 20, 10], [-10, -5, 21, 5]), isFalse);
    expect(viewportWithin([-20, -10, 20, 10], [-10, -11, 10, 5]), isFalse);
    expect(viewportWithin([170, -10, -170, 10], [175, -5, -175, 5]), isTrue);
    expect(viewportWithin([170, -10, -170, 10], [-175, -5, -165, 5]), isFalse);
    expect(viewportWithin([-180, -90, 180, 90], [175, -5, -175, 5]), isTrue);
    expect(viewportWithin([170, -10, -170, 10], [-180, -5, 180, 5]), isFalse);
  });

  test('local tap names the same cell as the shared web lattice', () {
    final vectors =
        jsonDecode(File('test/hit-vectors.json').readAsStringSync()) as List;
    for (final v in vectors) {
      expect(
        cellKey(v[0], (v[1] as num).toDouble(), (v[2] as num).toDouble()),
        v[3],
        reason: '$v',
      );
    }
  });
  test('selection ring remains centered on its cell across the world seam', () {
    for (final location in [
      [0.0, 0.0],
      [-0.0001, 47.0],
      [179.99, 84.0],
      [-179.99, -84.0],
    ]) {
      for (var level = 0; level < 6; level++) {
        final geometry = cellOutline(level, location[0], location[1]);
        final ring = geometry['coordinates'] as List;
        expect(ring.length, 97);
        expect(ring.first, ring.last);
        final key = cellKey(level, location[0], location[1]);
        // Shared edges have neighbour tie-breaking; verify the ring center.
        final points = ring.take(ring.length - 1).toList();
        final cx =
            points.fold<double>(0, (sum, p) => sum + mercX(p[0])) /
            points.length;
        final cy =
            points.fold<double>(0, (sum, p) => sum + mercY(p[1])) /
            points.length;
        expect(cellKey(level, longitude(cx), latitude(cy)), key);
        final xs = points.map((p) => mercX(p[0])).toList()..sort();
        expect(xs.last - xs.first, lessThan(30000));
      }
    }
  });
  test('place quantities use web precision and visit separators', () {
    expect(groupedNumber(1234567), '1,234,567');
    expect(formatGround(1234567), '1,234,567 km²');
    expect(formatGround(0.19), '0.2 km²');
    expect(formatPercent(0.001), '<0.01%');
    expect(formatPercent(0.012), '0.01%');
    expect(formatPercent(12.3), '12%');
  });
}
