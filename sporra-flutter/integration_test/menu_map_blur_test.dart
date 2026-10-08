import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:sporra_flutter/src/closing_blur.dart';
import 'package:sporra_flutter/src/sheets.dart' show Glass;

import 'menu_dismissal_test.dart' as pixels;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('menu retains native map blur and softens its complete edge', (
    tester,
  ) async {
    mb.MapboxOptions.setAccessToken('pk.sporra-local-test');
    final loaded = Completer<void>();
    final sigma = ValueNotifier(0.0);
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    addTearDown(sigma.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              mb.MapWidget(
                styleUri: '',
                viewport: mb.CameraViewportState(
                  center: mb.Point(coordinates: mb.Position(0, 0)),
                  zoom: 10,
                ),
                onMapCreated: (map) async {
                  await map.loadStyleJson(
                    jsonEncode({
                      'version': 8,
                      'sources': {
                        'street': {
                          'type': 'geojson',
                          'data': {
                            'type': 'Feature',
                            'properties': {},
                            'geometry': {
                              'type': 'LineString',
                              'coordinates': [
                                [-1, 0],
                                [1, 0],
                              ],
                            },
                          },
                        },
                      },
                      'layers': [
                        {
                          'id': 'base',
                          'type': 'background',
                          'paint': {'background-color': '#ffffff'},
                        },
                        {
                          'id': 'street',
                          'type': 'line',
                          'source': 'street',
                          'paint': {'line-color': '#000000', 'line-width': 14},
                        },
                      ],
                    }),
                  );
                },
                onStyleLoadedListener: (_) {
                  if (!loaded.isCompleted) loaded.complete();
                },
              ),
              Center(
                child: RepaintBoundary(
                  key: key,
                  child: SizedBox(
                    width: 320,
                    height: 240,
                    child: Center(
                      child: ListenableBuilder(
                        listenable: Listenable.merge([sigma, ready]),
                        builder: (_, child) => ClosingBlurScope(
                          sigma: sigma.value,
                          settledOpen: ready.value,
                          child: child!,
                        ),
                        child: const Glass(
                          child: SizedBox(width: 200, height: 120),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(
      () => loaded.future.timeout(const Duration(seconds: 20)),
    );
    await tester.pump(const Duration(seconds: 1));
    ready.value = true;
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final open = await pixels.nativePixels(
      binding,
      tester,
      boundary,
      'native-map-open',
    );
    int red(int x, int y) => open.getUint8((y * 320 + x) * 4);
    expect(red(40, 120), lessThan(60));
    expect(red(160, 120), greaterThan(70));
    sigma.value = 8;
    await tester.pump();
    final closed = await pixels.nativePixels(
      binding,
      tester,
      boundary,
      'native-map-closing',
    );
    int blurred(int x, int y) => closed.getUint8((y * 320 + x) * 4);
    expect(blurred(160, 120), greaterThan(70));
    for (var x = 53; x < 80; x++) {
      expect((blurred(x + 1, 105) - blurred(x, 105)).abs(), lessThan(28));
    }
    expect(tester.takeException(), isNull);
  });
}
