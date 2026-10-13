// The full geometry is the coverage guarantee, including when an older server
// or an offline cache supplies only spans with measurements.
Map<String, dynamic> activityMetricLines(
  Map<String, dynamic>? data,
  String? metric,
) {
  final features = <Map<String, dynamic>>[];
  if (data != null && metric != null) {
    for (final segment in data['route']?['geom'] as List? ?? []) {
      if ((segment as List).length < 2) continue;
      features.add({
        'type': 'Feature',
        'properties': {'color': '#ffffff', 'metricOrder': 0},
        'geometry': {'type': 'LineString', 'coordinates': segment},
      });
    }
    for (final feature in data['lines']?[metric]?['features'] as List? ?? []) {
      features.add({
        ...Map<String, dynamic>.from(feature),
        'properties': {...?feature['properties'] as Map?, 'metricOrder': 1},
      });
    }
  }
  return {'type': 'FeatureCollection', 'features': features};
}
