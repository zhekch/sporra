import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:sporra_flutter/src/native_map.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native Mapbox overlays, images, queries, camera and snapshot', (
    tester,
  ) async {
    // Deliberately invalid: this test only loads an in-memory style, so it
    // neither uses a developer credential nor needs a Mapbox tile download.
    mb.MapboxOptions.setAccessToken('pk.sporra-local-test');
    final created = Completer<mb.MapboxMap>();
    final loaded = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: mb.MapWidget(
          styleUri: '',
          viewport: mb.CameraViewportState(
            center: mapboxPoint(const LatLng(46.95, 7.45)),
            zoom: 10,
          ),
          onMapCreated: (map) async {
            created.complete(map);
            await map.loadStyleJson(
              jsonEncode({
                'version': 8,
                'sources': {},
                'layers': [
                  {
                    'id': 'background',
                    'type': 'background',
                    'paint': {'background-color': '#222222'},
                  },
                  {'id': 'bottom', 'type': 'slot'},
                  {'id': 'middle', 'type': 'slot'},
                  {'id': 'top', 'type': 'slot'},
                ],
              }),
            );
          },
          onStyleLoadedListener: (_) {
            if (!loaded.isCompleted) loaded.complete();
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() async {
      final map = await created.future.timeout(const Duration(seconds: 20));
      await loaded.future.timeout(const Duration(seconds: 20));
      final c = NativeMapController.box(map);
      await c.addSource(
        'points',
        GeojsonSourceProperties(
          data: {
            'type': 'FeatureCollection',
            'features': [
              {
                'type': 'Feature',
                'geometry': {
                  'type': 'Point',
                  'coordinates': [7.45, 46.95],
                },
                'properties': {'id': 42},
              },
            ],
          },
        ),
      );
      await c.addCircleLayer(
        'points',
        'test-pins',
        const CircleLayerProperties(circleRadius: 30, circleColor: '#ff0000'),
      );
      await c.addLineLayer(
        'points',
        'activities-line',
        const LineLayerProperties(
          lineWidth: 4,
          lineColor: '#ffffff',
          lineCap: 'round',
        ),
      );
      await c.setLayerProperties(
        'test-pins',
        const CircleLayerProperties(circleOpacity: 0.8),
      );
      final recorder = ui.PictureRecorder();
      Canvas(
        recorder,
      ).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = Colors.blue);
      final picture = recorder.endRecording();
      final image = await picture.toImage(8, 8);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      picture.dispose();
      const quad = LatLngQuad(
        topLeft: LatLng(47, 7),
        topRight: LatLng(47, 8),
        bottomRight: LatLng(46, 8),
        bottomLeft: LatLng(46, 7),
      );
      await c.addImageSource('sheet', bytes, quad);
      await c.addRasterLayer(
        'sheet',
        'blob-0',
        const RasterLayerProperties(rasterOpacity: 0.3),
      );
      await c.updateImageSource('sheet', bytes, quad);
      final state = await map.getCameraState();
      final pixel = await map.pixelForCoordinate(state.center);
      final point = await c.toLatLng(math.Point(pixel.x, pixel.y));
      expect(point.latitude, closeTo(46.95, 0.001));
      expect(point.longitude, closeTo(7.45, 0.001));
      final bounds = await c.getVisibleRegion();
      expect(bounds.contains(point), true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final hits = await c.queryRenderedFeaturesInRect(
        Rect.fromCenter(
          center: Offset(pixel.x, pixel.y),
          width: 40,
          height: 40,
        ),
        ['test-pins'],
        null,
      );
      expect(hits.single['properties']['id'], 42);
      expect(await c.getLayerIds(), containsAll(['test-pins', 'blob-0']));
      expect((await c.takeSnapshot()).length, greaterThan(100));
      await c.moveCamera(CameraUpdate.newLatLngZoom(const LatLng(47, 8), 8));
      expect(
        (await map.getCameraState()).center.coordinates.lng,
        closeTo(8, 0.001),
      );
      await c.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: const LatLng(46, 7),
            northeast: const LatLng(47, 8),
          ),
          bottom: 100,
        ),
        duration: const Duration(milliseconds: 100),
      );
      await c.setGeoJsonSource('points', {
        'type': 'FeatureCollection',
        'features': [],
      });
      await c.setLayerVisibility('test-pins', false);
    });
    await tester.pumpWidget(const SizedBox());
  });
}
