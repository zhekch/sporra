import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'map_interaction.dart';
import 'toast.dart';
import 'measured.dart';

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'blob.dart';
import 'state.dart';
import 'sheets.dart';
import 'activity_graph.dart';

// MapLibre's setter serializes omitted properties as null, which resets them.
// A patch must retain the colors/widths already installed on the native layer.
class LayerPatch implements LayerProperties {
  const LayerPatch(this.properties);
  final LayerProperties properties;
  @override
  Map<String, dynamic> toJson({bool skipNulls = true}) => properties.toJson();
}

const activityCardMaxHeight = 430.0;
const activityCardHeightShare = 0.64;

const styles = {
  'dark': 'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json',
  'voyager': 'https://basemaps.cartocdn.com/gl/voyager-gl-style/style.json',
  'terrain': 'https://tiles.openfreemap.org/styles/liberty',
};
String mapStyle(String style) =>
    styles[style] ??
    jsonEncode({
      'version': 8,
      'sources': {
        'satellite': {
          'type': 'raster',
          'tileSize': 256,
          'tiles': [
            'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
          ],
          'attribution': 'Esri, Maxar, Earthstar Geographics',
        },
      },
      'layers': [
        {'id': 'satellite', 'type': 'raster', 'source': 'satellite'},
      ],
    });

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});
  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  MapLibreMapController? map;
  final painter = BlobPainter();
  Future<void> patchLayer(String id, LayerProperties properties) =>
      map!.setLayerProperties(id, LayerPatch(properties));
  bool loaded = false, refreshing = false;
  bool pending = false;
  int generation = 0;
  int observed = -1;
  int? observedSample;
  dynamic observedActivity;
  int sheetSlot = 0;
  int currentLevel = 0;
  final sources = <String>{};
  final layers = <String>{};
  LatLng? location;
  bool locationEnabled = false;
  bool locating = false;
  CameraPosition camera = const CameraPosition(
    target: LatLng(46.95, 8.28),
    zoom: 7,
  );
  String? mapError;
  Map<String, dynamic>? placeInfo;
  Map<String, dynamic>? observedTrack;
  final cellFacts = <String, Map<String, dynamic>>{};
  final areaFacts = <({Path shape, Map<String, dynamic> info})>[];
  int factsLevel = -1;
  String? factsQuery;
  List<double>? factsBounds;
  int tapRequest = 0;
  List<Map<String, dynamic>> routeSummaries = [];
  int routesRevision = -1;
  int photosRevision = -1;
  String? observedError;
  Timer? fade;
  double activityCardHeight = 330, placeCardHeight = 150;
  Size mapSize = const Size(390, 844);
  final empty = {'type': 'FeatureCollection', 'features': <dynamic>[]};

  String? requestedStyle;
  String? resolvedStyle;
  final stroke = <Offset>[];
  Offset? pointer;
  Future<void> resolveStyle(AppState app, String name) async {
    try {
      final data = await app.api.get('/api/render/style?name=$name');
      if (mounted && requestedStyle == name) {
        setState(() => resolvedStyle = jsonEncode(data));
      }
    } catch (e) {
      if (mounted) setState(() => mapError = 'Basemap unavailable: $e');
    }
  }

  Future<void> finishStroke(AppState app) async {
    final pixels = List<Offset>.from(stroke);
    if (pixels.isEmpty) return;
    await app.run(() async {
      final points = <List<double>>[];
      for (final p in pixels) {
        final coord = await map!.toLatLng(math.Point(p.dx, p.dy));
        points.add([coord.longitude, coord.latitude]);
      }
      final result = await app.api.post('/api/render/brush', {
        'level': 0,
        'size': app.brushSize,
        'action': app.brushAction,
        'points': points,
      });
      app.undo = Map<String, dynamic>.from(result['undo']);
      app.changed();
    });
    if (mounted) {
      setState(() {
        stroke.clear();
        pointer = null;
      });
    }
  }

  Future<void> geoSource(String id, Map<String, dynamic> data) async {
    if (sources.contains(id)) {
      await map!.setGeoJsonSource(id, data);
    } else {
      await map!.addSource(
        id,
        GeojsonSourceProperties(
          data: data,
          tolerance: id == 'activity-metric' || id == 'trip' ? 0 : 0.375,
        ),
      );
      sources.add(id);
    }
  }

  Future<void> refresh() async {
    if (!mounted || !loaded || map == null) return;
    if (refreshing) {
      pending = true;
      return;
    }
    refreshing = true;
    final token = generation;
    final app = ref.read(appProvider);
    try {
      await updateRoutes(app);
      await updateActivityFocus(app);
      await updateTrack(app);
      if (!mounted || token != generation) return;
      final renderRevision = app.revision;
      final viewport = await map!.getVisibleRegion();
      final zoom = map!.cameraPosition?.zoom ?? 8;
      final level = app.detail == 'tiny'
          ? 0
          : app.detail == 'region'
          ? 6
          : app.detail == 'continent'
          ? 8
          : app.detail == 'country'
          ? 7
          : levelForZoom(zoom);
      currentLevel = level;
      var west = viewport.southwest.longitude,
          east = viewport.northeast.longitude;
      var span = east - west;
      if (span <= 0) span += 360;
      final pad = span * 0.35;
      final latPad =
          (viewport.northeast.latitude - viewport.southwest.latitude) * 0.35;
      final south = (viewport.southwest.latitude - latPad).clamp(
        -85.051129,
        85.051129,
      );
      final north = (viewport.northeast.latitude + latPad).clamp(
        -85.051129,
        85.051129,
      );
      if (span * 1.7 >= 360) {
        west = -180;
        east = 180;
      } else {
        west = ((west - pad + 180) % 360) - 180;
        east = ((east + pad + 180) % 360) - 180;
      }
      final bounds = <double>[west, south, east, north];
      final query =
          '${app.renderQuery(level, bbox: bounds.join(','))}&info=1&fine=${zoom >= regionFineZoom ? 1 : 0}';
      final data = Map<String, dynamic>.from(
        await app.api.get(
          '/api/render/${level < 6 ? 'cells' : 'regions'}?$query',
        ),
      );
      if (!mounted || token != generation || renderRevision != app.revision) {
        pending = true;
        return;
      }
      factsBounds = bounds;
      final alpha = app.accent.length == 9
          ? int.parse(app.accent.substring(7), radix: 16) / 255
          : 1.0;
      final opacity = app.mode == 'flat' ? 0.3 * alpha : 0.5;
      if (level < 6) {
        cellFacts.clear();
        for (final row in data['rows'] as List) {
          if (row.length > 5) {
            cellFacts['${row[0]}'] = Map<String, dynamic>.from(row[5]);
          }
        }
        factsLevel = level;
        factsQuery = (data['columns'] as List? ?? []).contains('info')
            ? app.renderQuery(level)
            : null;
        final width = math.min(
          1536,
          math.max(512, (mapSize.width * 1.7).round()),
        );
        final h =
            (width *
                    (mercY(north) - mercY(south)) /
                    (mercX(east <= west ? east + 360 : east) - mercX(west)))
                .round()
                .clamp(64, 1536);
        final sheet = await painter.paint(
          data,
          bounds,
          width,
          h,
          app.mode != 'flat',
        );
        if (!mounted || token != generation) return;
        final nextSlot = 1 - sheetSlot, id = 'blob-$nextSlot';
        if (sources.contains(id)) {
          await map!.updateImageSource(id, sheet.bytes, sheet.coordinates);
        } else {
          await map!.addImageSource(id, sheet.bytes, sheet.coordinates);
          sources.add(id);
          await map!.addRasterLayer(
            id,
            id,
            const RasterLayerProperties(
              rasterOpacity: 0,
              rasterFadeDuration: 0,
            ),
            belowLayerId: await below(),
          );
          layers.add(id);
        }
        fade?.cancel();
        final old = sheetSlot;
        sheetSlot = nextSlot;
        var step = 0;
        fade = Timer.periodic(const Duration(milliseconds: 31), (timer) {
          if (!mounted || token != generation) {
            timer.cancel();
            return;
          }
          final t = (++step / 20).clamp(0.0, 1.0);
          unawaited(
            patchLayer(
              id,
              RasterLayerProperties(rasterOpacity: opacity * t),
            ).catchError((_) {}),
          );
          if (layers.contains('blob-$old')) {
            unawaited(
              patchLayer(
                'blob-$old',
                RasterLayerProperties(rasterOpacity: opacity * (1 - t)),
              ).catchError((_) {}),
            );
          }
          if (t >= 1) timer.cancel();
        });
        if (layers.contains('areas-fill')) {
          await patchLayer(
            'areas-fill',
            const FillLayerProperties(fillOpacity: 0),
          );
        }
      } else {
        areaFacts.clear();
        for (final feature in data['infoFeatures'] ?? []) {
          final geometry = feature['geometry'];
          final polygons = geometry['type'] == 'Polygon'
              ? [geometry['coordinates']]
              : geometry['coordinates'];
          final shape = Path()..fillType = PathFillType.evenOdd;
          for (final polygon in polygons) {
            for (final ring in polygon) {
              if ((ring as List).isEmpty) continue;
              shape.moveTo(
                (ring.first[0] as num).toDouble(),
                (ring.first[1] as num).toDouble(),
              );
              for (final p in ring.skip(1)) {
                shape.lineTo(
                  (p[0] as num).toDouble(),
                  (p[1] as num).toDouble(),
                );
              }
              shape.close();
            }
          }
          areaFacts.add((
            shape: shape,
            info: Map<String, dynamic>.from(feature['properties']),
          ));
        }
        factsLevel = level;
        factsQuery = data.containsKey('infoFeatures')
            ? app.renderQuery(level)
            : null;
        final fills = Map<String, dynamic>.from(data)..remove('infoFeatures');
        fills['features'] = (data['features'] as List)
            .where((f) => f['properties']['k'] == 1)
            .toList();
        await geoSource('areas', fills);
        if (!layers.contains('areas-fill')) {
          await map!.addFillLayer(
            'areas',
            'areas-fill',
            FillLayerProperties(
              fillColor: ['get', 'color'],
              fillOpacity: opacity,
            ),
            belowLayerId: await below(),
          );
          layers.add('areas-fill');
        } else {
          await patchLayer(
            'areas-fill',
            FillLayerProperties(fillOpacity: opacity),
          );
        }
        fade?.cancel();
        for (final id in ['blob-0', 'blob-1']) {
          if (layers.contains(id)) {
            await patchLayer(id, const RasterLayerProperties(rasterOpacity: 0));
          }
        }
      }
      await updateOverlays(app);
      if (mounted) setState(() => mapError = null);
    } catch (e) {
      if (mounted) setState(() => mapError = '$e');
    } finally {
      refreshing = false;
      if (pending) {
        pending = false;
        unawaited(refresh());
      }
    }
  }

  Future<String?> below() async {
    final ids = await map!.getLayerIds();
    for (final id in ids) {
      if ('$id'.contains('label') || '$id'.contains('place')) return '$id';
    }
    return null;
  }

  Future<void> updateRoutes(AppState app) async {
    if (routesRevision != app.revision) {
      routeSummaries = List<Map<String, dynamic>>.from(
        (await app.api.get('/api/routes'))['routes'],
      );
      routesRevision = app.revision;
    }
    final data = app.routes
        ? Map<String, dynamic>.from(
            await app.api.get(
              '/api/render/routes${app.stackIds.isEmpty ? '' : '?${Uri(queryParameters: {'stack': app.stackIds.map((id) => '$id').toList()}).query}'}',
            ),
          )
        : Map<String, dynamic>.from(empty);
    if (app.selectedRoute != null) {
      data['features'] = (data['features'] as List)
          .where((f) => f['properties']['id'] == app.selectedRoute)
          .toList();
    }
    if (app.activity != null && app.activityMetric != null) {
      data['features'] = (data['features'] as List)
          .where((f) => f['properties']['id'] != app.activity!['route']['id'])
          .toList();
    }
    final light = app.style == 'voyager';
    for (final f in data['features'] as List) {
      final props = f['properties'] as Map;
      final hex = '${props['color']}';
      final rgb = int.parse(hex.substring(1), radix: 16);
      int mix(int shift) {
        final c = (rgb >> shift) & 255;
        return (light ? c * 0.7 : c + (255 - c) * 0.35).round();
      }

      props['coreColor'] =
          '#${((mix(16) << 16) | (mix(8) << 8) | mix(0)).toRadixString(16).padLeft(6, '0')}';
    }
    await geoSource('activities', data);
    final selected = app.activity?['route']['id'] ?? app.selectedRoute;
    final glow = [
      '*',
      ['get', 'alpha'],
      if (selected == null)
        (light ? 0.26 : 0.35)
      else
        [
          'case',
          [
            '==',
            ['get', 'id'],
            selected,
          ],
          light ? 0.5 : 0.6,
          light ? 0.26 : 0.35,
        ],
    ];
    // The web uses four concentric phone rings. Blur introduces cracks at
    // bends on the native renderer too, so use the same composited opacity.
    for (var ring = 1; ring <= 4; ring++) {
      final id = 'activities-glow-$ring';
      final props = LineLayerProperties(
        lineColor: ['get', 'color'],
        lineCap: 'round',
        lineJoin: 'round',
        lineWidth: routeWidth(
          selectedId: selected,
          scale: 3.4 * (5 - ring) / 4,
        ),
        lineOpacity: [
          '-',
          1,
          [
            '^',
            ['-', 1, glow],
            0.25,
          ],
        ],
      );
      if (layers.contains(id)) {
        await patchLayer(id, props);
      } else {
        await map!.addLineLayer('activities', id, props);
        layers.add(id);
      }
    }
    final core = LineLayerProperties(
      lineColor: ['get', 'coreColor'],
      lineCap: 'round',
      lineJoin: 'round',
      lineWidth: routeWidth(selectedId: selected),
      lineOpacity: [
        '*',
        0.95,
        ['get', 'alpha'],
      ],
    );
    if (layers.contains('activities-line')) {
      await patchLayer('activities-line', core);
    } else {
      await map!.addLineLayer('activities', 'activities-line', core);
      layers.add('activities-line');
    }
  }

  Future<void> updateTrack(AppState app) async {
    await geoSource(
      'trip',
      app.track == null
          ? Map<String, dynamic>.from(empty)
          : Map<String, dynamic>.from(app.track!['track']),
    );
    if (!layers.contains('trip-dot')) {
      await map!.addLineLayer(
        'trip',
        'trip-glow',
        const LineLayerProperties(
          lineCap: 'round',
          lineJoin: 'round',
          lineColor: trackColor,
          lineOpacity: 0.4,
          lineWidth: 9,
          lineBlur: 7,
        ),
      );
      await map!.addLineLayer(
        'trip',
        'trip-link',
        LineLayerProperties(
          lineCap: 'round',
          lineJoin: 'round',
          lineColor: trackColor,
          lineOpacity: 0.85,
          lineWidth: [
            'interpolate',
            ['linear'],
            ['zoom'],
            2,
            1.4,
            11,
            2.2,
            16,
            3,
          ],
        ),
      );
      await map!.addCircleLayer(
        'trip',
        'trip-dot',
        CircleLayerProperties(
          circleColor: trackColor,
          circleRadius: [
            'interpolate',
            ['linear'],
            ['zoom'],
            2,
            2.4,
            6,
            3.6,
            11,
            5.5,
            16,
            8,
          ],
          circleStrokeColor: 'rgba(14,16,22,0.75)',
          circleStrokeWidth: [
            'interpolate',
            ['linear'],
            ['zoom'],
            4,
            0.8,
            12,
            1.6,
          ],
        ),
      );
      layers.addAll(['trip-glow', 'trip-link', 'trip-dot']);
    }
  }

  Future<void> updateActivityFocus(AppState app) async {
    final data = app.activity;
    await geoSource(
      'activity-metric',
      data != null && app.activityMetric != null
          ? Map<String, dynamic>.from(data['lines'][app.activityMetric])
          : Map<String, dynamic>.from(empty),
    );
    if (!layers.contains('activity-metric-line')) {
      await map!.addLineLayer(
        'activity-metric',
        'activity-metric-casing',
        LineLayerProperties(
          lineCap: 'round',
          lineJoin: 'round',
          lineColor: 'rgba(20,16,12,0.85)',
          lineWidth: metricWidth(scale: 1.45),
          lineOpacity: 1,
        ),
      );
      layers.add('activity-metric-casing');
      await map!.addLineLayer(
        'activity-metric',
        'activity-metric-line',
        LineLayerProperties(
          lineColor: ['get', 'color'],
          lineCap: 'round',
          lineJoin: 'round',
          lineWidth: metricWidth(),
          lineOpacity: 1,
        ),
      );
      layers.add('activity-metric-line');
    }
    final sample = data != null && app.activitySample != null
        ? data['samples'][app.activitySample]
        : null;
    await geoSource('activity-cursor', {
      'type': 'FeatureCollection',
      'features': [
        if (sample != null)
          {
            'type': 'Feature',
            'properties': <String, dynamic>{},
            'geometry': {
              'type': 'Point',
              'coordinates': [sample['lng'], sample['lat']],
            },
          },
      ],
    });
    if (!layers.contains('activity-cursor-dot')) {
      await map!.addCircleLayer(
        'activity-cursor',
        'activity-cursor-dot',
        const CircleLayerProperties(
          circleRadius: 6,
          circleColor: '#ffffff',
          circleStrokeColor: '#262626',
          circleStrokeWidth: 2,
        ),
      );
      layers.add('activity-cursor-dot');
    }
  }

  Future<void> updateOverlays(AppState app) async {
    if (app.airports && !sources.contains('airports')) {
      await geoSource(
        'airports',
        Map<String, dynamic>.from(
          await app.api.get('/api/render/reference?kind=airports'),
        ),
      );
      await map!.addCircleLayer(
        'airports',
        'airport-pins',
        const CircleLayerProperties(
          circleColor: '#f4cc69',
          circleRadius: 4,
          circleStrokeColor: '#20252d',
          circleStrokeWidth: 1,
        ),
      );
      layers.add('airport-pins');
    }
    if (layers.contains('airport-pins')) {
      await patchLayer(
        'airport-pins',
        CircleLayerProperties(
          circleOpacity: app.airports ? 1 : 0,
          circleStrokeOpacity: app.airports ? 1 : 0,
        ),
      );
    }
    if (app.rail && !sources.contains('rail-ready')) {
      final data = await app.api.get('/api/render/reference?kind=rail');
      for (final entry in (data['sources'] as Map).entries) {
        final source = entry.value as Map;
        await map!.addSource(
          entry.key,
          VectorSourceProperties(
            tiles: List<String>.from(source['tiles']),
            minzoom: source['minzoom'],
            maxzoom: source['maxzoom'],
          ),
        );
        sources.add(entry.key);
      }
      final anchor = await below();
      for (final l in data['layers']) {
        await map!.addLineLayer(
          l['source'],
          l['id'],
          LineLayerProperties.fromJson(
            Map<String, dynamic>.from({...?l['paint'], ...?l['layout']}),
          ),
          sourceLayer: l['source-layer'],
          minzoom: (l['minzoom'] as num?)?.toDouble(),
          maxzoom: (l['maxzoom'] as num?)?.toDouble(),
          filter: l['filter'],
          belowLayerId: anchor,
        );
        layers.add(l['id']);
      }
      sources.add('rail-ready');
    }
    for (final id in layers.where((id) => id.startsWith('sporra-orm-'))) {
      await patchLayer(
        id,
        LineLayerProperties(visibility: app.rail ? 'visible' : 'none'),
      );
    }
    final trailSource = 'trails-${app.trailTheme}';
    final trailLayer = '$trailSource-layer';
    if (app.trails && !sources.contains(trailSource)) {
      await map!.addSource(
        trailSource,
        RasterSourceProperties(
          tiles: [
            app.api
                .uri('/api/trails/tile/${app.trailTheme}/{z}/{x}/{y}.png')
                .toString()
                .replaceAll('%7B', '{')
                .replaceAll('%7D', '}'),
          ],
          tileSize: 256,
          maxzoom: 18,
        ),
      );
      sources.add(trailSource);
      await map!.addRasterLayer(
        trailSource,
        trailLayer,
        RasterLayerProperties(
          rasterOpacity: app.trailStrength,
          rasterResampling: 'linear',
          rasterFadeDuration: 0,
        ),
        belowLayerId: await below(),
      );
      layers.add(trailLayer);
    }
    for (final id in layers.where(
      (id) => id.startsWith('trails-') && id.endsWith('-layer'),
    )) {
      await patchLayer(
        id,
        RasterLayerProperties(
          rasterOpacity: app.trails && id == trailLayer ? app.trailStrength : 0,
        ),
      );
    }
    if (app.photos &&
        (!sources.contains('photos') || photosRevision != app.revision)) {
      final photos = app.photosInTrack(await app.readPhotos());
      photosRevision = app.revision;
      await geoSource('photos', {
        'type': 'FeatureCollection',
        'features': photos
            .map(
              (p) => {
                'type': 'Feature',
                'properties': p,
                'geometry': {
                  'type': 'Point',
                  'coordinates': [p['lng'], p['lat']],
                },
              },
            )
            .toList(),
      });
      if (!layers.contains('photos-pins')) {
        await map!.addCircleLayer(
          'photos',
          'photos-pins',
          const CircleLayerProperties(
            circleColor: '#ffffff',
            circleRadius: 5,
            circleStrokeColor: '#60acff',
            circleStrokeWidth: 2,
          ),
        );
      }
      layers.add('photos-pins');
    }
    if (layers.contains('photos-pins')) {
      await patchLayer(
        'photos-pins',
        CircleLayerProperties(
          circleOpacity: app.photos ? 1 : 0,
          circleStrokeOpacity: app.photos ? 1 : 0,
        ),
      );
    }
  }

  Future<void> tap(LatLng point, {math.Point<double>? pixel}) async {
    final app = ref.read(appProvider);
    if (app.editing) {
      await app.run(() async {
        final result = await app.api.post(
          app.clearingRegion ? '/api/render/region-clear' : '/api/render/brush',
          {
            if (app.clearingRegion) ...{
              'lng': point.longitude,
              'lat': point.latitude,
            },
            'level': 0,
            'size': app.brushSize,
            'action': app.brushAction,
            'points': [
              [point.longitude, point.latitude],
            ],
          },
        );
        app.undo = Map<String, dynamic>.from(result['undo']);
        app.changed();
      });
      return;
    }
    final request = ++tapRequest;
    try {
      if (pixel != null) {
        final rect = Rect.fromCenter(
          center: Offset(pixel.x, pixel.y),
          width: routeTapPadding * 2,
          height: routeTapPadding * 2,
        );
        Future<List> query(List<String> ids) {
          final available = ids.where(layers.contains).toList();
          return available.isEmpty
              ? Future.value([])
              : map!.queryRenderedFeaturesInRect(rect, available, null);
        }

        // Native GeoJSON replies carry no layer id. Query categories separately
        // instead of trying to recover the JS SDK's feature.layer property.
        final results = await Future.wait([
          query(['activity-metric-line']),
          query(['photos-pins']),
          query(['airport-pins']),
          query(['activities-line']),
        ]);
        if (!mounted || request != tapRequest) return;
        if (results[0].isNotEmpty) {
          app.scrubActivity(
            (results[0].first['properties']['i'] as num).toInt(),
          );
          return;
        }
        if (results[1].isNotEmpty) {
          await showPhotos(
            context,
            app,
            indices: results[1]
                .map((f) => (f['properties']['index'] as num).toInt())
                .toSet(),
          );
          return;
        }
        if (results[2].isNotEmpty) {
          final hit = results[2].first;
          final coord = hit['geometry']['coordinates'];
          final data = await app.api.get(
            '/api/airport?lng=${coord[0]}&lat=${coord[1]}',
          );
          if (mounted && request == tapRequest) {
            await showAirport(
              context,
              Map<String, dynamic>.from(data['airport'] ?? hit['properties']),
            );
          }
          return;
        }
        final routeIds = results[3].map((f) => f['properties']['id']).toSet();
        if (routeIds.isNotEmpty) {
          setState(() => placeInfo = null);
          if (routeIds.length == 1) {
            await app.openActivity(routeIds.first);
          } else {
            final ordered =
                routeSummaries.where((r) => routeIds.contains(r['id'])).toList()
                  ..sort(
                    (a, b) =>
                        (b['firstAt'] as num).compareTo(a['firstAt'] as num),
                  );
            final groups = <String, List<Map<String, dynamic>>>{};
            for (final route in ordered) {
              final sport = '${route['sport'] ?? ''}';
              (groups[sport.isEmpty ? 'Not set' : sport] ??= []).add(route);
            }
            app.stackIds = groups.values
                .expand((routes) => routes)
                .map((r) => r['id'])
                .toList();
            app.changed();
            try {
              final stack = await app.api.get(
                '/api/render/routes?${Uri(queryParameters: {'stack': app.stackIds.map((id) => '$id').toList()}).query}',
              );
              final colors = {
                for (final f in stack['features'])
                  f['properties']['id']: '${f['properties']['color']}',
              };
              if (!mounted || request != tapRequest) return;
              await panel(
                context,
                'Choose an activity',
                ListView(
                  shrinkWrap: true,
                  children: [
                    for (final group in groups.entries) ...[
                      if (groups.length > 1) section(group.key),
                      for (final r in group.value)
                        ListTile(
                          leading: SizedBox(
                            width: 14,
                            height: 14,
                            child: FittedBox(
                              child: ColorDot(colors[r['id']] ?? '#ff9147'),
                            ),
                          ),
                          title: Text('${r['name']}'),
                          subtitle: Text(
                            '${date(r['firstAt'])} · ${((r['lengthM'] as num) / 1000).toStringAsFixed(1)} km',
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            app.openActivity(r['id']);
                          },
                        ),
                    ],
                  ],
                ),
                height: math.min(
                  0.42,
                  (76 + routeIds.length * 64) /
                      MediaQuery.sizeOf(context).height,
                ),
              );
            } finally {
              app.stackIds = [];
              app.changed();
            }
          }
          return;
        }
      }
      if (!app.cellInfo || app.activity != null) return;
      final b = factsBounds;
      final inBounds =
          b != null &&
          point.latitude >= b[1] &&
          point.latitude <= b[3] &&
          (b[0] <= b[2]
              ? point.longitude >= b[0] && point.longitude <= b[2]
              : point.longitude >= b[0] || point.longitude <= b[2]);
      final factsReady =
          inBounds &&
          factsLevel == currentLevel &&
          factsQuery == app.renderQuery(currentLevel);
      final local = factsReady
          ? currentLevel < 6
                ? cellFacts[cellKey(
                    currentLevel,
                    point.longitude,
                    point.latitude,
                  )]
                : areaFacts
                      .where(
                        (a) => a.shape.contains(
                          Offset(point.longitude, point.latitude),
                        ),
                      )
                      .firstOrNull
                      ?.info
          : null;
      setState(
        () => placeInfo = {
          'name': 'This place',
          if (factsReady) 'visited': local != null,
          ...?local,
        },
      );
      final info = await app.api.get(
        '/api/render/at?lng=${point.longitude}&lat=${point.latitude}&${app.renderQuery(currentLevel)}',
      );
      if (mounted && request == tapRequest && placeInfo != null) {
        setState(() => placeInfo = Map<String, dynamic>.from(info));
      }
    } catch (e) {
      if (mounted && request == tapRequest) {
        showToast(context, '$e', top: app.track == null ? 12 : 76);
      }
    }
  }

  @override
  void dispose() {
    generation++;
    tapRequest++;
    dismissToast();
    fade?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    if (app.activity != null) placeInfo = null;
    if (observedTrack != app.track) {
      observedTrack = app.track;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && map != null && app.track != null) goTo(map!, app.track!);
      });
    }
    if (observedError != app.error) {
      observedError = app.error;
      final message = app.error;
      if (message != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            showToast(context, message, top: app.track == null ? 12 : 76);
          }
        });
      }
    }
    if (requestedStyle != app.style) {
      requestedStyle = app.style;
      resolvedStyle = null;
      if (app.style == 'terrain' || app.style == 'satellite') {
        unawaited(resolveStyle(app, app.style));
      }
    }

    if (observed != app.revision) {
      observed = app.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(refresh());
      });
    }
    if (observedSample != app.activitySample) {
      observedSample = app.activitySample;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (loaded) unawaited(updateActivityFocus(app));
      });
    }
    if (observedActivity != app.activity?['route']['id']) {
      observedActivity = app.activity?['route']['id'];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (map != null && app.activity != null) {
          goTo(
            map!,
            app.activity!['route'],
            bottom: mapSize.width < 600 ? activityCardHeight + 60 : 150,
          );
        }
      });
    }
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          mapSize = constraints.biggest;
          return Stack(
            children: [
              MapLibreMap(
                key: ValueKey((app.style, resolvedStyle)),
                styleString: resolvedStyle ?? mapStyle(app.style),
                initialCameraPosition: camera,
                trackCameraPosition: true,
                featureTapsTriggersMapClick: true,
                myLocationEnabled: locationEnabled,
                myLocationRenderMode: locationEnabled
                    ? MyLocationRenderMode.compass
                    : MyLocationRenderMode.normal,
                scaleControlEnabled: true,
                attributionButtonPosition: AttributionButtonPosition.bottomLeft,
                attributionButtonMargins: math.Point(
                  12,
                  MediaQuery.paddingOf(context).bottom + 8,
                ),
                onMapCreated: (c) {
                  generation++;
                  loaded = false;
                  sources.clear();
                  layers.clear();
                  map = c;
                },
                onStyleLoadedCallback: () {
                  loaded = true;
                  unawaited(refresh());
                },
                onCameraIdle: () => unawaited(refresh()),
                onCameraMove: (p) {
                  camera = p;
                  if (p.tilt > 60) {
                    unawaited(map!.moveCamera(CameraUpdate.tiltTo(60)));
                  }
                },
                onUserLocationUpdated: (p) {
                  location = p.position;
                  if (locating && location != null) {
                    locating = false;
                    map?.animateCamera(
                      CameraUpdate.newLatLngZoom(location!, 13.6),
                    );
                  }
                },
                onMapClick: (pixel, p) => unawaited(tap(p, pixel: pixel)),
              ),
              if (app.editing && !app.clearingRegion)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: app.busy
                        ? null
                        : (d) => setState(() {
                            stroke.clear();
                            stroke.add(d.localPosition);
                            pointer = d.localPosition;
                          }),
                    onPanUpdate: app.busy
                        ? null
                        : (d) {
                            if (stroke.length < 2000 &&
                                (stroke.isEmpty ||
                                    (stroke.last - d.localPosition).distance >
                                        3)) {
                              setState(() {
                                stroke.add(d.localPosition);
                                pointer = d.localPosition;
                              });
                            }
                          },
                    onPanEnd: app.busy
                        ? null
                        : (_) => unawaited(finishStroke(app)),
                    onTapUp: app.busy
                        ? null
                        : (d) {
                            stroke.clear();
                            stroke.add(d.localPosition);
                            unawaited(finishStroke(app));
                          },
                    child: CustomPaint(
                      painter: StrokePreview(
                        List<Offset>.from(stroke),
                        pointer,
                        app.brushAction == 'erase'
                            ? Colors.orangeAccent
                            : Colors.lightBlueAccent,
                        math.max(
                          4,
                          app.brushSize *
                              42.7 *
                              math.pow(2, map?.cameraPosition?.zoom ?? 7) *
                              512 /
                              world,
                        ),
                      ),
                    ),
                  ),
                ),
              if (!app.menuOpen && !app.editing)
                SafeArea(
                  child: Align(
                    alignment: constraints.maxWidth < 600
                        ? Alignment.bottomRight
                        : Alignment.topLeft,
                    child: AnimatedPadding(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      padding: EdgeInsets.fromLTRB(
                        16,
                        16,
                        16,
                        16 +
                            (app.activity != null && constraints.maxWidth < 600
                                ? activityCardHeight + 14
                                : placeInfo != null
                                ? placeCardHeight + 14
                                : 0),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (camera.bearing.abs() > 1 || camera.tilt > 1)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Glass(
                                child: CupertinoButton(
                                  padding: const EdgeInsets.all(12),
                                  minimumSize: Size.zero,
                                  onPressed: () => map?.animateCamera(
                                    CameraUpdate.newCameraPosition(
                                      CameraPosition(
                                        target: camera.target,
                                        zoom: camera.zoom,
                                      ),
                                    ),
                                  ),
                                  child: Transform.rotate(
                                    angle: -camera.bearing * math.pi / 180,
                                    child: const Icon(
                                      CupertinoIcons.compass,
                                      color: Colors.white,
                                      size: 21,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Glass(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Search',
                                  onPressed: map == null
                                      ? null
                                      : () => showSporraSearch(
                                          context,
                                          app,
                                          map!,
                                        ),
                                  icon: const Icon(CupertinoIcons.search),
                                ),
                                IconButton(
                                  tooltip: 'Menu',
                                  onPressed: () => showMenuSheet(
                                    context,
                                    app,
                                    () => unawaited(refresh()),
                                    map,
                                  ),
                                  icon: const Icon(
                                    CupertinoIcons.line_horizontal_3,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Your location',
                                  onPressed: () {
                                    if (!locationEnabled) {
                                      setState(() {
                                        locationEnabled = true;
                                        locating = true;
                                      });
                                    } else if (location != null) {
                                      map?.animateCamera(
                                        CameraUpdate.newLatLngZoom(
                                          location!,
                                          13.6,
                                        ),
                                      );
                                    } else {
                                      showToast(
                                        context,
                                        'Allow location access in iOS Settings.',
                                      );
                                    }
                                  },
                                  icon: const Icon(CupertinoIcons.location),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (app.editing)
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 80, 48),
                      child: Glass(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Paint',
                              onPressed: () {
                                app.clearingRegion = false;
                                app.brushAction = 'paint';
                                app.changed();
                              },
                              icon: Icon(
                                Icons.brush,
                                color: app.brushAction == 'paint'
                                    ? Colors.lightBlueAccent
                                    : null,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Erase',
                              onPressed: () {
                                app.clearingRegion = false;
                                app.brushAction = 'erase';
                                app.changed();
                              },
                              icon: Icon(
                                Icons.auto_fix_normal,
                                color: app.brushAction == 'erase'
                                    ? Colors.lightBlueAccent
                                    : null,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Clear a region',
                              onPressed: () {
                                app.clearingRegion = !app.clearingRegion;
                                app.changed();
                              },
                              icon: Icon(
                                Icons.map_outlined,
                                color: app.clearingRegion
                                    ? Colors.orangeAccent
                                    : null,
                              ),
                            ),
                            DropdownButton<int>(
                              value: app.brushSize,
                              items: [1, 3, 8, 15, 24, 35, 48, 63, 80, 99]
                                  .map(
                                    (n) => DropdownMenuItem(
                                      value: n,
                                      child: Text('$n'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (n) {
                                app.brushSize = n!;
                                app.changed();
                              },
                            ),
                            IconButton(
                              tooltip: 'Undo',
                              onPressed: app.undo == null
                                  ? null
                                  : () => app.run(() async {
                                      final undo = app.undo!;
                                      await app.api.post('/api/cells/mutate', {
                                        'remove': undo['remove'],
                                      });
                                      await app.api.post('/api/cells/restore', {
                                        'rows': undo['rows'],
                                      });
                                      app.undo = null;
                                      app.changed();
                                    }),
                              icon: const Icon(Icons.undo),
                            ),
                            IconButton(
                              tooltip: 'Done editing',
                              onPressed: () {
                                app.editing = false;
                                app.changed();
                              },
                              icon: const Icon(Icons.check),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (placeInfo != null && !app.menuOpen && !app.editing)
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 380),
                        child: Measured(
                          onSize: (size) {
                            if (mounted && size.height != placeCardHeight) {
                              setState(() => placeCardHeight = size.height);
                            }
                          },
                          child: Dismissible(
                            key: const ValueKey('place-card'),
                            direction: DismissDirection.horizontal,
                            onDismissed: (_) => setState(() {
                              tapRequest++;
                              placeInfo = null;
                            }),
                            child: Glass(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  18,
                                  12,
                                  8,
                                  16,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${placeInfo!['name'] ?? 'This place'}',
                                            style: const TextStyle(
                                              fontSize: 17,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'Close place',
                                          onPressed: () => setState(() {
                                            tapRequest++;
                                            placeInfo = null;
                                          }),
                                          icon: const Icon(
                                            CupertinoIcons.xmark,
                                            size: 18,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      placeInfo!['visited'] == null
                                          ? 'Loading visit details…'
                                          : placeInfo!['visited'] == true
                                          ? 'You have been here'
                                          : 'No visits recorded',
                                    ),
                                    if (placeInfo!['visited'] == true) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        placeInfo!['hits'] == 0
                                            ? 'Marked by hand'
                                            : '${placeInfo!['hits']} visits',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                      Text(
                                        'First seen ${date(placeInfo!['firstAt'])} · Last seen ${date(placeInfo!['lastAt'])}',
                                        style: const TextStyle(
                                          color: Colors.white60,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (app.activity != null && !app.menuOpen && !app.editing)
                SafeArea(
                  child: Align(
                    alignment: constraints.maxWidth < 600
                        ? Alignment.bottomCenter
                        : Alignment.bottomLeft,
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: 10,
                        right: constraints.maxWidth < 600 ? 10 : 80,
                        bottom: 10,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: 440,
                          maxHeight: math.min(
                            activityCardMaxHeight,
                            constraints.maxHeight * activityCardHeightShare,
                          ),
                        ),
                        child: Measured(
                          onSize: (size) {
                            if (mounted && size.height != activityCardHeight) {
                              setState(() => activityCardHeight = size.height);
                            }
                          },
                          child: Dismissible(
                            key: ValueKey(
                              'activity-${app.activity!['route']['id']}',
                            ),
                            direction: DismissDirection.horizontal,
                            onDismissed: (_) => app.closeActivity(),
                            child: Glass(child: ActivityCard(app: app)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (app.track != null && app.activity == null)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Dismissible(
                        key: ValueKey(
                          'track-${app.trackDay ?? app.track!['id']}',
                        ),
                        direction: app.trackDay == null
                            ? DismissDirection.horizontal
                            : DismissDirection.up,
                        onDismissed: (_) => app.clearTrack(),
                        child: GestureDetector(
                          onHorizontalDragEnd: app.trackDay == null
                              ? null
                              : (d) {
                                  if ((d.primaryVelocity ?? 0).abs() >= 150) {
                                    app.stepDay(
                                      d.primaryVelocity! < 0 ? 1 : -1,
                                    );
                                  }
                                },
                          child: Glass(
                            radius: 24,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (app.trackDay != null && app.canStepDay(-1))
                                  IconButton(
                                    tooltip: 'Previous day',
                                    onPressed: () => app.stepDay(-1),
                                    icon: const Icon(
                                      CupertinoIcons.chevron_left,
                                      size: 16,
                                    ),
                                  ),
                                Flexible(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      10,
                                      8,
                                      10,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          app.trackDay == null ? 'TRIP' : 'DAY',
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: 1.2,
                                            color: Colors.white54,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          '${app.track!['label'] ?? app.track!['name']}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: -0.2,
                                            height: 1.2,
                                          ),
                                        ),
                                        if (app.trackDay != null &&
                                            app.track!['trip'] != null) ...[
                                          const SizedBox(height: 3),
                                          Text(
                                            '${(app.prefs['tripNames'] as Map?)?[app.track!['trip']['id']] ?? app.track!['trip']['name']}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.white60,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                if (app.trackDay != null && app.canStepDay(1))
                                  IconButton(
                                    tooltip: 'Next day',
                                    onPressed: () => app.stepDay(1),
                                    icon: const Icon(
                                      CupertinoIcons.chevron_right,
                                      size: 16,
                                    ),
                                  ),
                                if (app.trackDay == null &&
                                    app.track!['firstDay'] != null)
                                  IconButton(
                                    tooltip: 'Explore trip days',
                                    onPressed: () => app.selectTrack(
                                      day: '${app.track!['firstDay']}',
                                    ),
                                    icon: const Icon(
                                      CupertinoIcons.chevron_down,
                                      size: 16,
                                    ),
                                  ),
                                IconButton(
                                  tooltip: 'Clear trip',
                                  onPressed: app.clearTrack,
                                  icon: const Icon(
                                    CupertinoIcons.xmark,
                                    size: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (app.activity != null)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Dismissible(
                        key: ValueKey(
                          'workout-${app.activity!['route']['id']}',
                        ),
                        direction: DismissDirection.horizontal,
                        onDismissed: (_) => app.closeActivity(),
                        child: Glass(
                          radius: 24,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Previous workout',
                                  onPressed: app.busy
                                      ? null
                                      : () => app.run(() => app.stepActivity(-1)),
                                  icon: const Icon(
                                    CupertinoIcons.chevron_left,
                                    size: 16,
                                  ),
                                ),
                                Flexible(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${app.activity!['route']['sport'] ?? 'Workout'}'
                                                .isEmpty
                                            ? 'WORKOUT'
                                            : '${app.activity!['route']['sport']}'
                                                  .toUpperCase(),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: 1.2,
                                          color: Colors.white54,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${app.activity!['route']['name']}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: -0.2,
                                          height: 1.2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Next workout',
                                  onPressed: app.busy
                                      ? null
                                      : () => app.run(() => app.stepActivity(1)),
                                  icon: const Icon(
                                    CupertinoIcons.chevron_right,
                                    size: 16,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Close workout',
                                  onPressed: app.closeActivity,
                                  icon: const Icon(
                                    CupertinoIcons.xmark,
                                    size: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (app.clearingRegion)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Glass(
                        child: TextButton.icon(
                          icon: const Icon(Icons.close, size: 18),
                          label: Text(
                            app.clearingRegion
                                ? 'Tap a region to clear · Cancel'
                                : 'One activity · Show all',
                          ),
                          onPressed: () {
                            app.selectedRoute = null;
                            app.clearingRegion = false;
                            app.changed();
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              if (refreshing || app.busy)
                const SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                ),
              if (mapError != null)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        app.track == null ? 12 : 76,
                        16,
                        0,
                      ),
                      child: Dismissible(
                        key: ValueKey('map-error-$mapError'),
                        direction: DismissDirection.horizontal,
                        onDismissed: (_) => setState(() => mapError = null),
                        child: Glass(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(child: Text(mapError!)),
                                CupertinoButton(
                                  padding: const EdgeInsets.all(12),
                                  onPressed: () => unawaited(refresh()),
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class StrokePreview extends CustomPainter {
  StrokePreview(this.points, this.pointer, this.color, this.radius);
  final List<Offset> points;
  final Offset? pointer;
  final Color color;
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.isNotEmpty) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = radius * 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    if (pointer != null) {
      canvas.drawCircle(
        pointer!,
        radius,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant StrokePreview old) => true;
}
