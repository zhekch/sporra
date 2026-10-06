// Native iOS cannot use feature expressions for line-dasharray. Split a web
// match expression into equivalent filtered layers with constant dash arrays.
Iterable<Map<String, dynamic>> nativeRailLayers(
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
