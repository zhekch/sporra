import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

// Keep coincident assets grouped even at the highest supported map zoom.
const photoClusterRadius = 36.0;
const photoClusterMaxZoom = 24.0;
const photoLeafPageSize = 500;

GeojsonSourceProperties photoSource(List<dynamic> items) =>
    GeojsonSourceProperties(
      cluster: true,
      clusterRadius: photoClusterRadius,
      clusterMaxZoom: photoClusterMaxZoom,
      maxzoom: photoClusterMaxZoom,
      data: {
        'type': 'FeatureCollection',
        'features': [
          for (final p in items)
            {
              'type': 'Feature',
              'properties': p,
              'geometry': {
                'type': 'Point',
                'coordinates': [p['lng'], p['lat']],
              },
            },
        ],
      },
    );

const photoPinStyle = CircleLayerProperties(
  circleColor: '#ffffff',
  circleRadius: [
    'step',
    [
      'coalesce',
      ['get', 'point_count'],
      1,
    ],
    15,
    100,
    19,
    1000,
    23,
  ],
  circleStrokeColor: '#262626',
  circleStrokeWidth: 1.5,
);
const photoCountStyle = SymbolLayerProperties(
  textField: [
    'to-string',
    [
      'coalesce',
      ['get', 'point_count'],
      1,
    ],
  ],
  textSize: 12,
  textFont: ['Open Sans Regular'],
  textColor: '#262626',
  textAllowOverlap: true,
  textIgnorePlacement: true,
);

String photoCountTitle(List<dynamic> items) {
  final videos = items.where((p) => p['video'] == true).length;
  final photos = items.length - videos;
  return [
    if (photos > 0 || items.isEmpty)
      '$photos ${photos == 1 ? 'photo' : 'photos'}',
    if (videos > 0) '$videos ${videos == 1 ? 'video' : 'videos'}',
  ].join(' · ');
}

Map<String, dynamic> nearestPhotoHit(
  List<dynamic> hits,
  double lat,
  double lng,
) {
  double distance(dynamic hit) {
    final coordinates = hit['geometry']['coordinates'] as List;
    final dx =
        (((coordinates[0] as num) - lng + 540) % 360 - 180) *
        math.cos(lat * math.pi / 180);
    final dy = (coordinates[1] as num) - lat;
    return dx * dx + dy * dy;
  }

  var closest = hits.first;
  for (final hit in hits.skip(1)) {
    if (distance(hit) < distance(closest)) closest = hit;
  }
  return Map<String, dynamic>.from(closest);
}

Future<Set<int>> photoHitIndices(
  List<dynamic> hits,
  Future<List<dynamic>> Function(Map<String, dynamic>, int, int) leaves,
) async {
  final indices = <int>{};
  final clusters = <int>{};
  for (final hit in hits) {
    final props = hit['properties'] as Map;
    if (props['cluster_id'] is num && props['point_count'] is num) {
      final id = (props['cluster_id'] as num).toInt();
      if (!clusters.add(id)) continue;
      final count = (props['point_count'] as num).toInt();
      for (var offset = 0; offset < count;) {
        final page = await leaves(
          Map<String, dynamic>.from(hit),
          photoLeafPageSize,
          offset,
        );
        if (page.isEmpty) {
          throw StateError(
            'Photo group could not be read. Please tap it again.',
          );
        }
        for (final leaf in page) {
          indices.add((leaf['properties']['index'] as num).toInt());
        }
        offset += page.length;
      }
    } else if (props['index'] is num) {
      indices.add((props['index'] as num).toInt());
    }
  }
  return indices;
}
