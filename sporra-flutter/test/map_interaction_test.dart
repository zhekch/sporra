import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/map_interaction.dart';

void main() {
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
}
