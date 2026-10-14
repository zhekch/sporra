import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

// Simulator-only data; no account, session, location service or remote style.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'cached startup and live zoom do not wait for facts, validation or location',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'sporra-startup-',
      );
      final validation = Completer<http.Response>();
      final summaries = Completer<http.Response>();
      final facts = Completer<void>();
      var factsName = 'Fixture';
      final requests = <Uri>[];
      Map<String, Object> cells(int level, {bool info = false}) => {
        'level': level,
        'radius': 42,
        'columns': ['key', 'x', 'y', 'color', 'sparse', if (info) 'info'],
        'rows': [
          for (var i = 0; i < 40; i++)
            [
              cellKey(level, 8.28 + i * 0.0005, 46.95),
              mercX(8.28 + i * 0.0005),
              mercY(46.95),
              '#60acff',
              false,
              if (info) {'name': factsName, 'visited': true},
            ],
        ],
      };
      final app = AppState(
        api: SporraApi(
          client: MockClient((request) {
            requests.add(request.url);
            if (request.url.path == '/api/routes') return summaries.future;
            if (request.url.path == '/api/render/cells' &&
                request.url.queryParameters['info'] == '1') {
              expect(request.url.queryParameters.containsKey('bbox'), isTrue);
              return facts.future.then(
                (_) => http.Response(
                  jsonEncode(
                    cells(
                      int.parse(request.url.queryParameters['level']!),
                      info: true,
                    ),
                  ),
                  200,
                  headers: {'etag': '"facts"'},
                ),
              );
            }
            if (request.headers['If-None-Match'] == '"saved"') {
              return validation.future;
            }
            return Future.value(http.Response('{}', 200));
          }),
        )..server = 'https://example.test',
      );
      app.mapPreferences.latitude = 46.95;
      app.mapPreferences.longitude = 8.28;
      app.mapPreferences.zoom = 14;
      final route = {
        'type': 'Feature',
        'properties': {'id': 1, 'color': '#ff9147', 'alpha': 1},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [8.28, 46.95],
            [8.30, 46.951],
          ],
        },
      };
      final snapshots = <String, Object>{
        '/api/prefs': {'prefs': {}},
        '/api/render/routes': {
          'type': 'FeatureCollection',
          'features': [route],
        },
        for (var level = 0; level < 3; level++)
          app.mapDataPath(level): cells(level),
      };
      final file = File('${directory.path}/responses.json');
      final bodies = Directory('${file.path}.data');
      await bodies.create();
      final entries = <Map<String, Object?>>[];
      var id = 0;
      for (final snapshot in snapshots.entries) {
        final body = jsonEncode(snapshot.value);
        await File('${bodies.path}/$id.json').writeAsString(body);
        entries.add({
          'url': 'https://example.test${snapshot.key}',
          'tag': '"saved"',
          'id': id++,
          'size': body.length * 2,
          'at': DateTime.now()
              .subtract(const Duration(days: 800))
              .millisecondsSinceEpoch,
        });
      }
      await file.writeAsString(
        jsonEncode({
          'scope': 'https://example.test\nalice',
          'format': SporraApi.cacheFormat,
          'nextFile': id,
          'entries': entries,
        }),
      );
      await app.api.restore(file, 'alice');
      await app.loadPrefs();
      final clock = Stopwatch()..start();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appProvider.overrideWith((ref) => app)],
          child: MaterialApp(
            home: MapScreen(
              enableLocation: false,
              styleOverride: jsonEncode({
                'version': 8,
                'sources': {},
                'layers': [
                  {
                    'id': 'background',
                    'type': 'background',
                    'paint': {'background-color': '#202020'},
                  },
                ],
              }),
            ),
          ),
        ),
      );
      final dynamic screen = tester.state(find.byType(MapScreen));
      // A pending fix used to suppress the entire ground refresh.
      screen.focusingLocation = true;
      Future<void> until(
        bool Function() condition, {
        Duration timeout = const Duration(seconds: 30),
      }) async {
        final wait = Stopwatch()..start();
        while (!condition()) {
          if (wait.elapsed > timeout) {
            fail(
              'Map did not progress: error=${screen.mapError}, zoom=${screen.camera.zoom}, '
              'facts=${screen.factsLevel}, live=${screen.renderedLive}, moving=${screen.cameraMoving}, '
              'painted=${screen.renderedAt != null}, routes=${screen.routesView != null}, '
              'details=${screen.loadingFacts}, detailsRequests=${requests.where((url) => url.queryParameters["info"] == "1").length}',
            );
          }
          await tester.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      }

      await until(
        () =>
            screen.renderedAt != null &&
            screen.routesView != null &&
            requests.any((url) => url.queryParameters['info'] == '1') &&
            !screen.refreshing,
      );
      expect(screen.factsLevel, 0);
      expect(screen.cellFacts, isNotEmpty);
      expect(validation.isCompleted, isFalse);
      expect(screen.focusingLocation, isTrue);
      expect(summaries.isCompleted, isFalse);
      expect(facts.isCompleted, isFalse);
      screen.showCachedPlace(const LatLng(46.95, 8.28), app);
      expect(screen.placeInfo['visited'], isTrue);
      expect(screen.placeInfo['name'], isNull);
      final native = screen.map.libre as MapLibreMapController;
      expect(
        await native.querySourceFeatures('activities', null, null),
        isNotEmpty,
      );
      expect(requests.any((url) => url.path == '/api/render/cells'), isTrue);
      expect(requests.any((url) => url.path == '/api/render/routes'), isTrue);
      // ignore: avoid_print
      print('SPORRA_CACHED_STARTUP_MS ${clock.elapsedMilliseconds}');

      screen.focusingLocation = false;
      final before = screen.renderedAt;
      final cellReads = requests
          .where((url) => url.path == '/api/render/cells')
          .length;
      await tester.runAsync(() async {
        unawaited(
          native.animateCamera(
            CameraUpdate.zoomTo(12.7),
            duration: const Duration(seconds: 4),
          ),
        );
      });
      await until(
        () =>
            screen.cameraMoving &&
            screen.renderedLive &&
            screen.factsLevel == 1 &&
            screen.renderedAt != before,
        timeout: const Duration(seconds: 3),
      );
      expect(validation.isCompleted, isFalse);
      expect(facts.isCompleted, isFalse);
      expect(
        requests.where((url) => url.path == '/api/render/cells').length,
        cellReads,
        reason: 'Warm gesture frames use local snapshots without additional HTTP requests.',
      );
      // ignore: avoid_print
      print('SPORRA_LIVE_ZOOM_BEFORE_IDLE true');
      await until(
        () =>
            !screen.cameraMoving &&
            !screen.refreshing &&
            !screen.renderedLive &&
            screen.factsLevel == 1 &&
            screen.activeFactsPath != null &&
            Uri.parse(screen.activeFactsPath as String)
                    .queryParameters['level'] ==
                '1',
      );
      screen.showCachedPlace(const LatLng(46.95, 8.28), app);
      final painted = screen.renderedAt;
      facts.complete();
      await until(
        () => screen.placeInfo?['name'] == 'Fixture' && !screen.loadingFacts,
      );
      expect(
        screen.renderedAt,
        painted,
        reason: 'Visit details never repaint the cell image.',
      );
      await tester.runAsync(() async {
        factsName = 'Updated fixture';
        await app.api
            .get(screen.activeFactsPath as String, refresh: true)
            .timeout(const Duration(seconds: 5));
      });
      await until(() => screen.placeInfo?['name'] == 'Updated fixture');
      expect(
        screen.renderedAt,
        painted,
        reason: 'Changed background facts update the selected place only.',
      );
      expect(screen.mapError, isNull);
      expect(tester.takeException(), isNull);
      summaries.complete(http.Response('{"routes":[],"duplicates":{}}', 200));
      validation.complete(http.Response('', 304));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await app.api.flushCache();
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await directory.delete(recursive: true);
    },
  );
}
