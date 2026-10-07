// Native iOS cannot use feature expressions for line-dasharray. Split a web
// match expression into equivalent filtered layers with constant dash arrays.
Iterable<Map<String, dynamic>> _nativeDashLayers(
  Map<String, dynamic> layer,
) sync* {
  final paint = Map<String, dynamic>.from(layer['paint'] ?? {});
  final dash = paint['line-dasharray'];
  if (dash is! List || dash.isEmpty || dash.first != 'match') {
    yield layer;
    return;
  }
  final input = dash[1];
  final conditions = <dynamic>[];
  for (var i = 2; i < dash.length - 1; i += 2) {
    final label = dash[i];
    final labels = label is List ? label : [label];
    final condition = [
      'in',
      input,
      ['literal', labels],
    ];
    conditions.add(condition);
    yield _withDash(layer, paint, dash[i + 1], condition, '$i');
  }
  yield _withDash(layer, paint, dash.last, [
    '!',
    ['any', ...conditions],
  ], 'default');
}

Map<String, dynamic> _withDash(
  Map<String, dynamic> layer,
  Map<String, dynamic> paint,
  dynamic value,
  dynamic condition,
  String suffix,
) {
  final dash = value is List && value.first == 'literal' ? value[1] : value;
  return {
    ...layer,
    'id': '${layer['id']}-dash-$suffix',
    'paint': {...paint, 'line-dasharray': dash},
    'filter': ['all', if (layer['filter'] != null) layer['filter'], condition],
  };
}

// The UIKit property bridge cannot infer colors returned by a case expression.
// Express each branch as a filtered layer with a constant color instead.
Iterable<Map<String, dynamic>> nativeRailLayers(
  Map<String, dynamic> layer,
) sync* {
  for (final dashed in _nativeDashLayers(layer)) {
    yield* _nativeColorLayers(dashed);
  }
}

Iterable<Map<String, dynamic>> _nativeColorLayers(
  Map<String, dynamic> layer,
) sync* {
  final paint = Map<String, dynamic>.from(layer['paint'] ?? {});
  for (final entry in paint.entries) {
    final value = entry.value;
    if (!entry.key.endsWith('color') ||
        value is! List ||
        value.isEmpty ||
        !['case', 'match'].contains(value.first)) {
      continue;
    }
    final conditions = <dynamic>[];
    final start = value.first == 'case' ? 1 : 2;
    for (var i = start; i < value.length - 1; i += 2) {
      final condition = value.first == 'case'
          ? value[i]
          : [
              'in',
              value[1],
              [
                'literal',
                value[i] is List ? value[i] : [value[i]],
              ],
            ];
      final filter = [
        'all',
        if (layer['filter'] != null) layer['filter'],
        if (conditions.isNotEmpty)
          [
            '!',
            ['any', ...conditions],
          ],
        condition,
      ];
      yield* _nativeColorLayers({
        ...layer,
        'id': '${layer['id']}-${entry.key}-$i',
        'paint': {...paint, entry.key: value[i + 1]},
        'filter': filter,
      });
      conditions.add(condition);
    }
    yield* _nativeColorLayers({
      ...layer,
      'id': '${layer['id']}-${entry.key}-default',
      'paint': {...paint, entry.key: value.last},
      'filter': [
        'all',
        if (layer['filter'] != null) layer['filter'],
        [
          '!',
          ['any', ...conditions],
        ],
      ],
    });
    return;
  }
  yield layer;
}
