import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:sporra_flutter/src/native_map.dart';
import 'package:sporra_flutter/src/photo_markers.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final box in [false, true]) {
    testWidgets(
      '${box ? 'Mapbox' : 'MapLibre'} photo counts and full group paging',
      (tester) async {
        final ready = Completer<NativeMapController>();
        final loaded = Completer<void>();
        final style = jsonEncode({
          'version': 8,
          'glyphs': 'https://tiles.basemaps.cartocdn.com/fonts/{fontstack}/{range}.pbf',
          'sources': {},
          'layers': [
            {
              'id': 'background',
              'type': 'background',
              'paint': {'background-color': '#222222'},
            },
          ],
        });
        if (box) mb.MapboxOptions.setAccessToken('pk.sporra-local-test');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: box
                  ? mb.MapWidget(
                      styleUri: '',
                      viewport: mb.CameraViewportState(
                        center: mapboxPoint(const LatLng(46.95, 7.45)),
                        zoom: 10,
                      ),
                      onMapCreated: (map) async {
                        ready.complete(NativeMapController.box(map));
                        await map.loadStyleJson(style);
                      },
                      onStyleLoadedListener: (_) {
                        if (!loaded.isCompleted) loaded.complete();
                      },
                    )
                  : MapLibreMap(
                      styleString: style,
                      initialCameraPosition: const CameraPosition(
                        target: LatLng(46.95, 7.45),
                        zoom: 10,
                      ),
                      onMapCreated: (map) =>
                          ready.complete(NativeMapController.libre(map)),
                      onStyleLoadedCallback: () {
                        if (!loaded.isCompleted) loaded.complete();
                      },
                    ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        late NativeMapController map;
        await tester.runAsync(() async {
          map = await ready.future.timeout(const Duration(seconds: 20));
          await loaded.future.timeout(const Duration(seconds: 20));
          await map.addSource(
            'photos',
            photoSource(
              List.generate(
                503,
                (i) => {'index': i, 'lat': 46.95, 'lng': 7.45, 'video': i == 1},
              ),
            ),
          );
          await map.addCircleLayer('photos', 'photos-pins', photoPinStyle);
          await map.addSymbolLayer('photos', 'photos-counts', photoCountStyle);
          await Future<void>.delayed(const Duration(seconds: 3));
        });
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(seconds: 5));
          final center = map.box != null
              ? await map.box!.pixelForCoordinate(
                  mapboxPoint(const LatLng(46.95, 7.45)),
                )
              : null;
          final libreCenter = map.libre != null
              ? await map.libre!.toScreenLocation(const LatLng(46.95, 7.45))
              : null;
          final rect = Rect.fromCenter(
            center: Offset(
              center?.x ?? libreCenter!.x.toDouble(),
              center?.y ?? libreCenter!.y.toDouble(),
            ),
            width: 40,
            height: 40,
          );
          final hits = await map.queryRenderedFeaturesInRect(rect, [
            'photos-pins',
          ], null);
          expect(hits, isNotEmpty);
          expect(hits.first['properties']['point_count'], 503);
          final ids = await photoHitIndices(
            hits,
            (cluster, limit, offset) => map.getClusterLeaves(
              'photos',
              cluster,
              limit: limit,
              offset: offset,
            ),
          );
          expect(ids, Set<int>.from(List.generate(503, (i) => i)));
          final labels = await map.queryRenderedFeaturesInRect(rect, [
            'photos-counts',
          ], null);
          expect(labels, isNotEmpty, reason: 'count label must render');
          await map.setLayerVisibility('photos-counts', false);
          await Future<void>.delayed(const Duration(milliseconds: 500));
          expect(
            await map.queryRenderedFeaturesInRect(rect, [
              'photos-counts',
            ], null),
            isEmpty,
          );
          await map.setLayerVisibility('photos-counts', true);
        });
        await tester.pump(const Duration(milliseconds: 100));
        await binding.takeScreenshot(
          'photo-count-${box ? 'mapbox' : 'maplibre'}',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
