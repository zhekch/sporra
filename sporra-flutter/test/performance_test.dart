import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/blob.dart';
import 'package:sporra_flutter/src/cell_snapshot.dart';
import 'package:sporra_flutter/src/map_screen.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  test('large cached viewport benchmark', () async {
    final random = Random(3);
    final rows = List.generate(
      50000,
      (i) => [
        '$i',
        mercX(random.nextDouble() * 360),
        mercY(random.nextDouble() * 160 - 80),
        '#60acff',
        false,
        {
          'name': 'Recorded place',
          'hits': 3,
          'visitDates': ['2026-01-01', '2026-01-02'],
          'sources': ['sample-source'],
        },
      ],
    );
    final json = jsonEncode({'level': 0, 'radius': 42, 'rows': rows});
    final bounds = <double>[7, 46, 9, 48];
    final reader = CellSnapshotReader();
    addTearDown(reader.dispose);
    await reader.read('bench', json, bounds);
    final baseline = <int>[], indexed = <int>[];
    for (var i = 0; i < 5; i++) {
      var clock = Stopwatch()..start();
      final decoded = await SporraApi.decodeJson(json);
      final before = cellsInBounds(decoded['rows'], bounds);
      baseline.add(clock.elapsedMicroseconds);
      clock = Stopwatch()..start();
      final after = await reader.read('bench', json, bounds);
      indexed.add(clock.elapsedMicroseconds);
      expect(after['rows'], before);
    }
    baseline.sort();
    indexed.sort();
    // These are host processing measurements, not end-to-end phone timings.
    // ignore: avoid_print
    print(
      'SPORRA_VIEWPORT_BENCHMARK ${jsonEncode({'rows': rows.length, 'json_bytes': json.length, 'baseline_median_ms': baseline[2] / 1000, 'indexed_median_ms': indexed[2] / 1000})}',
    );
  }, skip: !const bool.fromEnvironment('SPORRA_BENCHMARK'));

  test(
    'indexed snapshots match directed viewport clipping and preserve row order',
    () async {
      final random = Random(7);
      final rows = List.generate(20000, (i) {
        final lng = random.nextDouble() * 360;
        final lat = random.nextDouble() * 160 - 80;
        return [
          '$i',
          mercX(lng),
          mercY(lat),
          '#60acff',
          false,
          {
            'visits': [i],
          },
        ];
      });
      final json = jsonEncode({'level': 0, 'radius': 42, 'rows': rows});
      final reader = CellSnapshotReader();
      addTearDown(reader.dispose);
      for (final bounds in <List<double>>[
        [7, 46, 9, 48],
        [-2, -10, 2, 10],
        [170, -20, -170, 20],
        [-180, -85, 180, 85],
        [-130, 20, -100, 60],
        [0, -85, 180, 85],
      ]) {
        final result = await reader.read('snapshot', json, bounds);
        expect(result['rows'], cellsInBounds(rows, bounds));
      }
      final first = await reader.read('snapshot', json, [-180, -85, 180, 85]);
      first['rows'][0][5]['visits'].clear();
      final second = await reader.read('snapshot', json, [-180, -85, 180, 85]);
      expect(second['rows'][0][5]['visits'], [0]);
      final changed = await reader.read('snapshot', '{"rows":[]}', [
        -180,
        -85,
        180,
        85,
      ]);
      expect(changed['rows'], isEmpty);
    },
  );

  test(
    'activity selection and opacity preserve the prepared ground identity',
    () {
      final app = AppState();
      addTearDown(app.dispose);
      Object key() =>
          groundRenderKey(app, 1, 0, 0, false, const Size(390, 844));
      final before = key();
      app.activity = {
        'route': {'id': 7},
      };
      app.selectedRoute = 7;
      app.mapOpacity = 0.8;
      app.ground = false;
      app.changed();
      expect(key(), before);
      app.hidden.add('source');
      expect(key(), isNot(before));
      app.hidden.clear();
      app.api.clear();
      expect(key(), isNot(before));
    },
  );

  test(
    'preference writes retain every ground zoom and in-flight cell reads',
    () async {
      final response = Completer<http.Response>();
      var mapReads = 0;
      final api = SporraApi(
        client: MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response('{"ok":true}', 200);
          }
          if (request.url.path == '/api/render/cells') {
            mapReads++;
            return response.future;
          }
          return http.Response('{"features":[]}', 200);
        }),
      )..server = 'https://example.test';
      addTearDown(api.dispose);
      final ground = api.revisionFor('/api/render/cells');
      final routes = api.revisionFor('/api/render/routes');
      final reading = api.get('/api/render/cells?level=0');
      await api.post('/api/prefs', {
        'prefs': {
          'mapOpacities': {'flat': 0.8},
        },
      });
      response.complete(http.Response('{"rows":[]}', 200));
      await reading;
      await api.get('/api/render/cells?level=0');
      expect(mapReads, 1);
      expect(api.revisionFor('/api/render/cells'), ground);
      expect(api.revisionFor('/api/render/routes'), isNot(routes));
    },
  );

  test(
    'refreshed activity details retain the current visibility selection',
    () async {
      var name = 'Saved activity';
      final app = AppState(
        api: SporraApi(
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'route': {'id': 7, 'name': name},
                'graphs': {},
              }),
              200,
            ),
          ),
        )..server = 'https://example.test',
      );
      addTearDown(app.dispose);
      await app.openActivity(7);
      app.selectedRoute = null;
      final request = app.activityRequest;
      name = 'Updated activity';
      await app.api.get('/api/render/activity?id=7', refresh: true);
      await Future<void>.delayed(Duration.zero);
      expect(app.activity!['route']['name'], name);
      expect(app.selectedRoute, isNull);
      expect(app.activityRequest, request);
    },
  );

  testWidgets(
    'saved menu data appears before a delayed refresh and updates afterwards',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('sporra-latency-'),
      ))!;
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/responses.json');
      await tester.runAsync(
        () => file.writeAsString(
          jsonEncode({
            'scope': 'https://example.test\nalice',
            'entries': [
              {
                'url': 'https://example.test/api/trips',
                'tag': '"old"',
                'json': '{"label":"Saved trips"}',
                'at': DateTime.now()
                    .subtract(const Duration(days: 1))
                    .millisecondsSinceEpoch,
              },
            ],
          }),
        ),
      );
      final response = Completer<http.Response>();
      var requests = 0;
      final api = SporraApi(
        client: MockClient((_) {
          requests++;
          return response.future;
        }),
      )..server = 'https://example.test';
      addTearDown(api.dispose);
      await tester.runAsync(() => api.restore(file, 'alice'));
      await tester.pumpWidget(
        MaterialApp(
          home: AsyncList(
            api: api,
            paths: const {'/api/trips'},
            load: () => api.get('/api/trips', allowStale: true),
            builder: (_, data) => Text(data['label']),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Saved trips'), findsOneWidget);
      expect(requests, 1);
      response.complete(http.Response('{"label":"Updated trips"}', 200));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('Updated trips'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );

  testWidgets('large activity groups build only the visible rows', (
    tester,
  ) async {
    final routes = List.generate(
      10000,
      (i) => {
        'id': i,
        'name': 'Activity $i',
        'firstAt': i + 1,
        'lengthM': i,
        'sport': 'Walking',
        'source': 'apple-health',
        'thumb': '0,0 100,100',
      },
    );
    final app = AppState(
      api: SporraApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'routes': routes, 'distance': '100 km', 'years': []}),
            200,
          ),
        ),
      )..server = 'https://example.test',
    );
    addTearDown(app.dispose);
    await tester.runAsync(() => app.api.get('/api/render/activity-stats'));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: activitiesList(app))),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('By app'));
    await tester.pumpAndSettle();
    expect(find.byType(ActivityMiniature).evaluate().length, lessThan(30));
    expect(find.text('Activity 9999'), findsOneWidget);
    expect(find.text('Activity 0'), findsNothing);
    await tester.tap(find.text('Apple health · 10000'));
    await tester.pumpAndSettle();
    expect(find.byType(ActivityMiniature), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
