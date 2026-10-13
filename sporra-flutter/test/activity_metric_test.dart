import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/activity_metric.dart';

void main() {
  test('a cached partial metric keeps the entire recorded route in white', () {
    final route = [
      [
        [7, 46],
        [7.1, 46],
        [7.2, 46],
        [7.3, 46],
      ],
      [
        [8, 46],
        [8.1, 46],
      ],
      [
        [9, 46],
      ],
    ];
    final measured = {
      'type': 'Feature',
      'properties': {'color': '#ffff00', 'i': 3},
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          [7.2, 46],
          [7.3, 46],
        ],
      },
    };
    final data = <String, dynamic>{
      'route': {'geom': route},
      'lines': {
        'elev': {
          'type': 'FeatureCollection',
          'features': [measured],
        },
      },
    };
    final original = jsonEncode(data);
    final features = activityMetricLines(data, 'elev')['features'] as List;
    expect(features.length, 3);
    expect(features.take(2).map((f) => f['properties']['color']), [
      '#ffffff',
      '#ffffff',
    ]);
    expect(features[0]['geometry']['coordinates'], route[0]);
    expect(features[1]['geometry']['coordinates'], route[1]);
    expect(features[2]['properties']['color'], '#ffff00');
    expect(features[2]['properties']['i'], 3);
    expect(features.map((f) => f['properties']['metricOrder']), [0, 0, 1]);
    expect(
      jsonEncode(data),
      original,
      reason: 'cached payloads must remain unchanged',
    );
  });

  test(
    'missing metric collections still draw geometry and closing clears it',
    () {
      final data = <String, dynamic>{
        'route': {
          'geom': [
            [
              [7, 46],
              [7.1, 46],
            ],
          ],
        },
      };
      expect(
        (activityMetricLines(data, 'elev')['features'] as List)
            .single['properties']['color'],
        '#ffffff',
      );
      expect(activityMetricLines(data, null)['features'], isEmpty);
      expect(activityMetricLines(null, 'elev')['features'], isEmpty);
    },
  );
}
