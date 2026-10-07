// Start the synthetic reference server with:
// node sporra-webserver/scripts/test/native-rail-preview.mjs
import 'dart:async';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:sporra_flutter/src/native_map.dart';
import 'package:sporra_flutter/src/rail_style.dart';
import 'package:sporra_flutter/src/api.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final box in [false, true]) {
    testWidgets(
      '${box ? 'Mapbox' : 'MapLibre'} installs all native railway groups',
      (tester) async {
        final ready = Completer<NativeMapController>(),
            loaded = Completer<void>();
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
                        zoom: 15,
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
                        zoom: 15,
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
          final api = SporraApi()
            ..server = const String.fromEnvironment(
              'RAIL_REFERENCE_URL',
              defaultValue: 'http://127.0.0.1:3217',
            );
          final data = await api.get('/');
          api.client.close();
          await map.addSource(
            'rail-fixture',
            GeojsonSourceProperties(
              data: {
                'type': 'FeatureCollection',
                'features': [
                  {
                    'type': 'Feature',
                    'properties': {
                      'railway': 'rail',
                      'usage': 'main',
                      'state': 'present',
                      'service': '',
                      'feature': 'station',
                      'name': 'Rail test',
                      'ref': '1',
                      'layer': 0,
                      'tunnel': false,
                      'bridge': false,
                    },
                    'geometry': {
                      'type': 'LineString',
                      'coordinates': [
                        [7.44, 46.95],
                        [7.46, 46.95],
                      ],
                    },
                  },
                ],
              },
            ),
          );
          final specs = (data['layers'] as List)
              .expand((l) => nativeRailLayers(Map<String, dynamic>.from(l)))
              .toList();
          for (final spec in specs) {
            final layer = Map<String, dynamic>.from(spec)
              ..remove('source-layer');
            layer['source'] = 'rail-fixture';
            await map.addReferenceLayer(layer);
            await map.setLayerVisibility(
              layer['id'],
              layer['layout']?['visibility'] != 'none',
            );
          }
          final ids = await map.getLayerIds();
          for (final layer in specs) {
            expect(ids, contains(layer['id']));
          }
          await map.removeLayer(specs.last['id']);
          expect(await map.getLayerIds(), isNot(contains(specs.last['id'])));
        });
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        await binding.takeScreenshot(
          'native-rail-${box ? 'mapbox' : 'maplibre'}',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }
}
