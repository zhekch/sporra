import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/rail_style.dart';

void main() {
  test(
    'native color branches preserve priority, metadata and source filters',
    () {
      final original = [
        '==',
        ['get', 'state'],
        'present',
      ];
      final layers = nativeRailLayers({
        'id': 'station',
        'type': 'symbol',
        'source': 'rail',
        'source-layer': 'stations',
        'metadata': {'sporra:group': 'stations'},
        'filter': original,
        'paint': {
          'text-color': [
            'case',
            [
              '==',
              ['get', 'station'],
              'tram',
            ],
            '#ff0000',
            [
              '==',
              ['get', 'station'],
              'subway',
            ],
            '#0000ff',
            '#ffffff',
          ],
          'text-halo-color': '#333333',
        },
      }).toList();
      expect(layers.length, 3);
      expect(layers.map((l) => l['paint']['text-color']), [
        '#ff0000',
        '#0000ff',
        '#ffffff',
      ]);
      expect(layers[1]['filter'][2], [
        '!',
        [
          'any',
          [
            '==',
            ['get', 'station'],
            'tram',
          ],
        ],
      ]);
      for (final l in layers) {
        expect(l['filter'][1], original);
        expect(l['source-layer'], 'stations');
        expect(l['metadata']['sporra:group'], 'stations');
      }
    },
  );
  test('native railway dash cases retain filters and fallback', () {
    final layers = nativeRailLayers({
      'id': 'rail',
      'source': 'tracks',
      'filter': [
        '==',
        ['get', 'railway'],
        'rail',
      ],
      'paint': {
        'line-width': 2,
        'line-dasharray': [
          'match',
          ['get', 'state'],
          'construction',
          [
            'literal',
            [4.5, 4.5],
          ],
          ['proposed', 'abandoned'],
          [
            'literal',
            [1, 4],
          ],
          [
            'literal',
            [100, 0],
          ],
        ],
      },
    }).toList();
    expect(layers.length, 3);
    expect(layers.map((l) => l['id']).toSet().length, 3);
    expect(layers[0]['paint']['line-dasharray'], [4.5, 4.5]);
    expect(layers[1]['paint']['line-dasharray'], [1, 4]);
    expect(layers[2]['paint']['line-dasharray'], [100, 0]);
    expect(layers[0]['filter'][1], [
      '==',
      ['get', 'railway'],
      'rail',
    ]);
    expect(layers[2]['filter'][2][0], '!');
  });
}
