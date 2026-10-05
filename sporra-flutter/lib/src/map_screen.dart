import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'blob.dart';
import 'state.dart';
import 'sheets.dart';

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
  bool loaded = false, refreshing = false;
  bool pending = false;
  int generation = 0;
  int observed = -1;
  int sheetSlot = 0;
  int currentLevel = 0;
  final sources = <String>{};
  final layers = <String>{};
  LatLng? location;
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
    if (!loaded || map == null) return;
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
      final opacity = app.mode == 'flat' ? 0.3 : 0.5;
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
            map!
                .setLayerProperties(
                  id,
                  RasterLayerProperties(rasterOpacity: opacity * t),
                )
                .catchError((_) {}),
          );
          if (layers.contains('blob-$old')) {
            unawaited(
              map!
                  .setLayerProperties(
                    'blob-$old',
                    RasterLayerProperties(rasterOpacity: opacity * (1 - t)),
                  )
                  .catchError((_) {}),
            );
          }
          if (t >= 1) timer.cancel();
        });
        if (layers.contains('areas-fill')) {
          await map!.setLayerProperties(
            'areas-fill',
            const FillLayerProperties(fillOpacity: 0),
          );
        }
      } else {
        await geoSource('areas', data);
        if (!layers.contains('areas-fill')) {
          await map!.addFillLayer(
            'areas',
            'areas-fill',
            FillLayerProperties(
              fillColor: ['get', 'color'],
              fillOpacity: opacity,
            ),
            filter: [
              '==',
              ['get', 'k'],
              1,
            ],
            belowLayerId: await below(),
          );
          layers.add('areas-fill');
        } else {
          await map!.setLayerProperties(
            'areas-fill',
            FillLayerProperties(fillOpacity: opacity),
          );
        }
        fade?.cancel();
        for (final id in ['blob-0', 'blob-1']) {
          if (layers.contains(id)) {
            await map!.setLayerProperties(
              id,
              const RasterLayerProperties(rasterOpacity: 0),
            );
          }
        }
      }
      await updateRoutes(app);
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
    final result = app.routes
        ? await app.api.get('/api/routes?geom=1')
        : {'routes': []};
    final features = <Map<String, dynamic>>[];
    for (final r in result['routes']) {
      for (final segment in r['geom'] ?? []) {
        if ((segment as List).length < 2) continue;
        features.add({
          'type': 'Feature',
          'properties': {'name': r['name'], 'id': r['id']},
          'geometry': {'type': 'LineString', 'coordinates': segment},
        });
      }
    }
    await geoSource('activities', {
      'type': 'FeatureCollection',
      'features': features,
    });
    if (!layers.contains('activities-line')) {
      await map!.addLineLayer(
        'activities',
        'activities-glow',
        const LineLayerProperties(
          lineColor: '#60acff',
          lineWidth: 7,
          lineOpacity: 0.2,
          lineBlur: 3,
        ),
      );
      layers.add('activities-glow');
      await map!.addLineLayer(
        'activities',
        'activities-line',
        const LineLayerProperties(
          lineColor: '#60acff',
          lineWidth: 2.5,
          lineOpacity: 0.9,
        ),
      );
      layers.add('activities-line');
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
      if (layer == 'photos-pins') {
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
      await map!.setLayerProperties(
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
      await map!.setLayerProperties(
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
      await map!.setLayerProperties(
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
      await map!.setLayerProperties(
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
        final result = await app.api.post('/api/render/brush', {
          'level': 0,
          'size': app.brushSize,
          'action': app.brushAction,
          'points': [
            [point.longitude, point.latitude],
          ],
        });
        app.undo = Map<String, dynamic>.from(result['undo']);
        app.changed();
      });
      return;
    }
    try {
      final info = await app.api.get(
        '/api/render/at?lng=${point.longitude}&lat=${point.latitude}&level=$currentLevel',
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
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          mapSize = constraints.biggest;
          return Stack(
            children: [
              MapLibreMap(
                key: ValueKey((app.style, resolvedStyle)),
                styleString: resolvedStyle ?? mapStyle(app.style),
                initialCameraPosition: const CameraPosition(
                  target: LatLng(46.95, 8.28),
                  zoom: 7,
                ),
                trackCameraPosition: true,
                myLocationEnabled: true,
                myLocationRenderMode: MyLocationRenderMode.compass,
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
                  if (p.tilt > 60) {
                    unawaited(map!.moveCamera(CameraUpdate.tiltTo(60)));
                  }
                },
                onUserLocationUpdated: (p) => location = p.position,
                onMapClick: (_, p) => unawaited(tap(p)),
              ),
              if (app.editing)
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
                    alignment: Alignment.topLeft,
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
                            onPressed: () =>
                                showSporraSearch(context, app, map!),
                            icon: const Icon(Icons.search),
                          ),
                          IconButton(
                            tooltip: 'Trips and calendar',
                            onPressed: () => showTrips(context, app, map!),
                            icon: const Icon(Icons.calendar_month),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Glass(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Your location',
                            onPressed: () {
                              if (location != null) {
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
                            tooltip: 'Refresh',
                            onPressed: () => unawaited(refresh()),
                            icon: const Icon(Icons.refresh),
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
