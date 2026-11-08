import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/blob.dart';
import 'package:sporra_flutter/src/map_interaction.dart';
import 'package:sporra_flutter/src/map_screen.dart';
import 'package:sporra_flutter/src/state.dart';

// Self-contained simulator fixture. It never opens or edits an account, calls
// initialize/login/sign-out, or uses the phone's existing session.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('latest zoom paints without waiting for an obsolete download', (
    tester,
  ) async {
    final oldLevel = Completer<http.Response>();
    final overlay = Completer<http.Response>();
    final closingGround = Completer<http.Response>();
    var closingGroundRequested = false;
    var oldRequested = false, geometryReads = 0;
    var regionReads = 0;
    var overlayRequested = false;
    final rows = [
      for (var i = 0; i < 40; i++)
        [
          cellKey(0, 8.28 + i * 0.0005, 46.95),
          mercX(8.28 + i * 0.0005),
          mercY(46.95),
          '#60acff',
          false,
          {'name': 'Fixture', 'visited': true},
        ],
    ];
    final routeFeatures = [
      for (var i = 1; i <= 2; i++)
        {
          'type': 'Feature',
          'properties': {'id': i, 'color': '#ff9147', 'alpha': 1},
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [8.28, 46.95],
              [8.30, 46.95 + i * 0.001],
            ],
          },
        },
    ];
    final app = AppState(
      api: SporraApi(
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/api/render/cells') {
            final level = int.parse(request.url.queryParameters['level']!);
            final info = request.url.queryParameters['info'] == '1';
            if (level == 5 && !info && !oldRequested) {
              oldRequested = true;
              return oldLevel.future;
            }
            if (level == 2 && !info && !closingGroundRequested) {
              closingGroundRequested = true;
              return closingGround.future;
            }
            return http.Response(
              jsonEncode({
                'level': level,
                'radius': 42,
                'columns': [
                  'key',
                  'x',
                  'y',
                  'color',
                  'sparse',
                  if (info) 'info',
                ],
                'rows': info
                    ? rows
                    : [for (final row in rows) row.take(5).toList()],
              }),
              200,
            );
          }
          if (path == '/api/routes') {
            return http.Response('{"routes":[],"duplicates":{}}', 200);
          }
          if (path == '/api/render/routes') {
            geometryReads++;
            return http.Response(
              jsonEncode({
                'type': 'FeatureCollection',
                'features': routeFeatures,
              }),
              200,
            );
          }
          if (path == '/api/render/regions') {
            regionReads++;
            return http.Response(
              '{"type":"FeatureCollection","features":[],"infoFeatures":[]}',
              200,
            );
          }
          if (path == '/api/render/reference') {
            overlayRequested = true;
            return overlay.future;
          }
          return http.Response('{"ok":true}', 200);
        }),
      )..server = 'https://example.test',
    );
    final localStyle = jsonEncode({
      'version': 8,
      'sources': {},
      'layers': [
        {
          'id': 'background',
          'type': 'background',
          'paint': {'background-color': '#202020'},
        },
      ],
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((ref) => app)],
        child: MaterialApp(
          home: MapScreen(styleOverride: localStyle, enableLocation: false),
        ),
      ),
    );
    final dynamic screen = tester.state(find.byType(MapScreen));
    screen.setState(() {
      screen.locating = false;
      screen.locationEnabled = false;
    });
    await tester.pump();
    Future<void> until(bool Function() condition) async {
      final clock = Stopwatch()..start();
      while (!condition()) {
        if (clock.elapsed > const Duration(seconds: 30)) {
          fail(
            'Native map did not settle: error=${screen.mapError}, loaded=${screen.loaded}, '
            'zoom=${screen.camera.zoom}, level=${screen.currentLevel}, facts=${screen.factsLevel}, '
            'refreshing=${screen.refreshing}, pending=${screen.pending}',
          );
        }
        await tester.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }

    await until(() => oldRequested);
    final clock = Stopwatch()..start();
    await tester.runAsync(
      () => screen.map
          .moveCamera(CameraUpdate.newLatLngZoom(const LatLng(46.95, 8.28), 14))
          .timeout(const Duration(seconds: 5)),
    );
    await until(() => screen.factsLevel == 0 && !screen.refreshing);
    expect(oldLevel.isCompleted, isFalse);
    expect(screen.cellFacts, isNotEmpty);
    // ignore: avoid_print
    print('SPORRA_SIMULATOR_ZOOM_MS ${clock.elapsedMilliseconds}');
    oldLevel.complete(
      http.Response(jsonEncode({'level': 5, 'radius': 42, 'rows': rows}), 200),
    );
    await until(() => screen.routeRefreshWork == null);
    app.api.cancelPrefetch();
    app.airports = true;
    app.changed();
    await tester.pump();
    await until(() => overlayRequested);
    await tester.runAsync(
      () => screen.map.moveCamera(
        CameraUpdate.newLatLngZoom(const LatLng(46.95, 8.28), 13),
      ),
    );
    await until(() => screen.factsLevel == 1 && !screen.refreshing);
    expect(
      overlay.isCompleted,
      isFalse,
      reason: 'Reference downloads cannot block the next ground level.',
    );
    overlay.complete(
      http.Response(
        '{"type":"FeatureCollection","features":[],"layers":[]}',
        200,
      ),
    );
    await until(() => screen.overlayRefreshWork == null);
    app.airports = false;
    app.changed();
    await tester.pump();
    await until(() => !screen.refreshing && screen.overlayRefreshWork == null);
    final paintedAt = screen.renderedAt;
    app.selectedRoute = 1;
    app.mapOpacity = 0.8;
    app.changed();
    await tester.pump();
    await tester.runAsync(() => screen.refresh());
    await until(() => !screen.refreshing && screen.routeRefreshWork == null);
    expect(
      screen.renderedAt,
      paintedAt,
      reason: 'Selection and opacity retain the visited image.',
    );
    expect(geometryReads, 1);
    final controller = screen.map.libre as MapLibreMapController;
    final stored = await controller.querySourceFeatures(
      'activities',
      null,
      null,
    );
    expect(stored.map((feature) => feature['properties']['id']).toSet(), {
      1,
      2,
    });
    expect(
      await controller.getFilter('activities-line'),
      activityFilter(1, null),
    );
    app.applyActivity({
      'route': {
        'id': 1,
        'name': 'Fixture',
        'sport': 'Ride',
        'firstAt': 1700000000000,
        'geom': [(routeFeatures.first['geometry'] as Map)['coordinates']],
      },
      'summary': {'distance': '100 m'},
      'graphs': <String, dynamic>{},
      'samples': [],
    });
    app.activityMetric = 'speed';
    app.changed();
    await tester.pump();
    await until(
      () =>
          screen.routeRefreshWork == null &&
          screen.activityFocusWork == null &&
          !screen.refreshing,
    );
    expect(await controller.getFilter('activities-line'), activityFilter(1, 1));
    await tester.runAsync(
      () => screen.map.moveCamera(
        CameraUpdate.newLatLngZoom(const LatLng(46.95, 8.28), 11.5),
      ),
    );
    await until(
      () =>
          closingGroundRequested &&
          screen.refreshing &&
          screen.currentLevel == 2 &&
          screen.routeRefreshWork == null &&
          screen.activityFocusWork == null,
    );
    app.closeActivity();
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(closingGround.isCompleted, isFalse);
    // The plugin's getFilter crashes when its native predicate simplifies to
    // boolean true; query the actually rendered collection after closing.
    final restoredLines = await screen.map.queryRenderedFeaturesInRect(
      Rect.fromLTWH(0, 0, screen.mapSize.width, screen.mapSize.height),
      ['activities-line'],
      null,
    ) as List;
    expect(
      restoredLines.map((feature) => feature['properties']['id']).toSet(),
      {1, 2},
      reason: 'Closing restores all activity lines while a ground download is still pending.',
    );
    closingGround.complete(
      http.Response(jsonEncode({'level': 2, 'radius': 42, 'rows': rows}), 200),
    );
    await until(() => !screen.refreshing && screen.activityFocusWork == null);
    app.detail = 'country';
    app.changed();
    await tester.pump();
    await until(() => screen.factsLevel == 7 && !screen.refreshing);
    final regionAt = screen.renderedAt;
    final previousRegionReads = regionReads;
    await tester.runAsync(
      () => screen.map.moveCamera(
        CameraUpdate.newLatLngZoom(const LatLng(20, 30), 6),
      ),
    );
    await until(
      () =>
          screen.camera.zoom < 10 &&
          (screen.camera.target.latitude - 20).abs() < 1e-4 &&
          !screen.refreshing,
    );
    expect(
      screen.renderedAt,
      regionAt,
      reason: 'Account-wide areas survive panning and zooming.',
    );
    expect(
      regionReads,
      previousRegionReads + 1,
      reason: 'Idle validates cached areas without resending unchanged native geometry.',
    );
    expect(screen.mapError, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
