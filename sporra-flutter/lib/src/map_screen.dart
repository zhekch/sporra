import 'dart:async';
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
  Timer? fade;
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
      await map!.addGeoJsonSource(id, data);
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
      final query = app.renderQuery(level, bbox: bounds.join(','));
      final data = Map<String, dynamic>.from(
        await app.api.get(
          '/api/render/${level < 6 ? 'cells' : 'regions'}?$query',
        ),
      );
      if (!mounted || token != generation) return;
      final alpha = app.accent.length == 9
          ? int.parse(app.accent.substring(7), radix: 16) / 255
          : 1.0;
      final opacity = app.mode == 'flat' ? 0.3 * alpha : 0.5;
      if (level < 6) {
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
        final fills = Map<String, dynamic>.from(data);
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
      await updateRoutes(app);
      await updateOverlays(app);
      await updateActivityFocus(app);
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
    final data = app.routes
        ? Map<String, dynamic>.from(await app.api.get('/api/render/routes'))
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
    await geoSource('activities', data);
    if (!layers.contains('activities-line')) {
      await map!.addLineLayer(
        'activities',
        'activities-glow',
        LineLayerProperties(
          lineColor: ['get', 'color'],
          lineWidth: 7,
          lineOpacity: [
            '*',
            0.2,
            ['get', 'alpha'],
          ],
          lineBlur: 3,
        ),
      );
      layers.add('activities-glow');
      await map!.addLineLayer(
        'activities',
        'activities-line',
        LineLayerProperties(
          lineColor: ['get', 'color'],
          lineWidth: 2.5,
          lineOpacity: [
            '*',
            0.9,
            ['get', 'alpha'],
          ],
        ),
      );
      layers.add('activities-line');
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
        'activity-metric-line',
        LineLayerProperties(
          lineColor: ['get', 'color'],
          lineWidth: 4,
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

  Future<void> featureTap(
    math.Point<double> point,
    LatLng coord,
    String id,
    String layer,
    Annotation? annotation,
  ) async {
    final app = ref.read(appProvider);
    try {
      final features = await map!.queryRenderedFeatures(point, [layer], null);
      if (features.isEmpty || !mounted) return;
      final properties = Map<String, dynamic>.from(
        features.first['properties'] ?? {},
      );
      if (layer == 'activity-metric-line') {
        app.scrubActivity((properties['i'] as num).toInt());
      } else if (layer == 'photos-pins') {
        await showPhotos(context, app);
      } else if (layer == 'activities-line') {
        final data = await app.api.get('/api/routes?geom=1');
        final route = (data['routes'] as List)
            .where((r) => r['id'] == properties['id'])
            .firstOrNull;
        if (mounted && route != null) {
          await showRoute(context, app, Map<String, dynamic>.from(route));
        }
      } else if (layer == 'airport-pins') {
        final data = await app.api.get(
          '/api/airport?lng=${coord.longitude}&lat=${coord.latitude}',
        );
        if (mounted) {
          await showAirport(
            context,
            Map<String, dynamic>.from(data['airport'] ?? properties),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
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
    if (app.trails && !sources.contains('trails')) {
      await map!.addSource(
        'trails',
        RasterSourceProperties(
          tiles: [
            app.api
                .uri('/api/trails/tile/hiking/{z}/{x}/{y}.png')
                .toString()
                .replaceAll('%7B', '{')
                .replaceAll('%7D', '}'),
          ],
          tileSize: 256,
        ),
      );
      sources.add('trails');
      await map!.addRasterLayer(
        'trails',
        'trails-layer',
        const RasterLayerProperties(rasterOpacity: 0.65),
        belowLayerId: await below(),
      );
      layers.add('trails-layer');
    }
    if (layers.contains('trails-layer')) {
      await patchLayer(
        'trails-layer',
        RasterLayerProperties(rasterOpacity: app.trails ? 0.65 : 0),
      );
    }
    if (app.photos && !sources.contains('photos')) {
      final photos = jsonDecode(await app.native.photos()) as List;
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

  Future<void> tap(LatLng point) async {
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
    try {
      if (!app.cellInfo || app.activity != null) return;
      final info = await app.api.get(
        '/api/render/at?lng=${point.longitude}&lat=${point.latitude}&${app.renderQuery(currentLevel)}',
      );
      if (mounted) await showInfo(context, Map<String, dynamic>.from(info));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  void dispose() {
    generation++;
    fade?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
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
            bottom: mapSize.width < 600
                ? math.min(
                        activityCardMaxHeight,
                        mapSize.height * activityCardHeightShare,
                      ) +
                      60
                : 150,
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
                myLocationEnabled: locationEnabled,
                myLocationRenderMode: locationEnabled
                    ? MyLocationRenderMode.compass
                    : MyLocationRenderMode.normal,
                scaleControlEnabled: true,
                attributionButtonPosition: AttributionButtonPosition.topRight,
                onMapCreated: (c) {
                  generation++;
                  loaded = false;
                  sources.clear();
                  layers.clear();
                  map = c;
                  c.onFeatureTapped.add(featureTap);
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
                onMapClick: (_, p) => unawaited(tap(p)),
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
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    alignment:
                        constraints.maxWidth < 600 &&
                            constraints.maxHeight > 560
                        ? Alignment.bottomRight
                        : Alignment.topLeft,
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom:
                            constraints.maxWidth < 600 &&
                                constraints.maxHeight > 560
                            ? 112 +
                                  (app.activity != null
                                      ? math.min(
                                              activityCardMaxHeight,
                                              constraints.maxHeight *
                                                  activityCardHeightShare,
                                            ) +
                                            10
                                      : 0)
                            : 0,
                      ),
                      child: Glass(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Menu',
                              onPressed: () => showMenuSheet(
                                context,
                                app,
                                () => unawaited(refresh()),
                                map,
                              ),
                              icon: const Icon(Icons.menu),
                            ),
                            IconButton(
                              tooltip: 'Search',
                              onPressed: () => map == null
                                  ? null
                                  : showSporraSearch(context, app, map!),
                              icon: const Icon(Icons.search),
                            ),
                            IconButton(
                              tooltip: 'Trips and calendar',
                              onPressed: map == null
                                  ? null
                                  : () => showTrips(context, app, map!),
                              icon: const Icon(Icons.calendar_month),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    16,
                    16,
                    16 +
                        (app.activity != null && constraints.maxWidth < 600
                            ? math.min(
                                    activityCardMaxHeight,
                                    constraints.maxHeight *
                                        activityCardHeightShare,
                                  ) +
                                  10
                            : 0),
                  ),
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Glass(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
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
                                  CameraUpdate.newLatLngZoom(location!, 13.6),
                                );
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Allow location access in iOS Settings.',
                                    ),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.my_location),
                          ),
                          IconButton(
                            tooltip: 'Reset compass',
                            onPressed: () => map?.animateCamera(
                              CameraUpdate.newCameraPosition(
                                CameraPosition(
                                  target: map!.cameraPosition!.target,
                                  zoom: map!.cameraPosition!.zoom,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.explore_outlined),
                          ),
                        ],
                      ),
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
              if (app.activity != null)
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
                        child: Glass(child: ActivityCard(app: app)),
                      ),
                    ),
                  ),
                ),
              if (app.selectedRoute != null || app.clearingRegion)
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
              if (mapError != null || app.error != null)
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        bottom: 100,
                        left: 16,
                        right: 16,
                      ),
                      child: Glass(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(mapError ?? app.error!),
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
