import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/appearance.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  testWidgets(
    'colour segment reselect toggles ground; another segment changes mode',
    (tester) async {
      var reselected = 0;
      String? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChoiceRow(
              value: 'flat',
              choices: const {'flat': 'Single', 'visits': 'Visits'},
              onReselected: () => reselected++,
              onChanged: (v) => changed = v,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Single'));
      await tester.pumpAndSettle();
      expect(reselected, 1);
      expect(changed, isNull);
      await tester.tap(find.text('Visits'));
      await tester.pumpAndSettle();
      expect(changed, 'visits');
      expect(reselected, 1);
    },
  );

  test('random activity colors preserve hidden types and disable per-route rainbow', () async {
    Map? saved;
    final app = AppState(
      api: SporraApi(
        client: MockClient((request) async {
          if (request.url.path == '/api/render/activity-palette') {
            expect(jsonDecode(request.body)['keys'], ['Run', '\u0000none']);
            return http.Response(
              jsonEncode({
                'colors': {'Run': '#df4949', '\u0000none': '#45a160'},
              }),
              200,
            );
          }
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'prefs': {
                  'routeView': {
                    'hidden': ['Run'],
                    'colors': {'Ride': '#0000ff'},
                    'rainbow': true,
                  },
                  'clock': '24',
                },
              }),
              200,
            );
          }
          saved = jsonDecode(request.body)['prefs'];
          return http.Response('{"ok":true}', 200);
        }),
      )..server = 'https://example.test',
    );
    addTearDown(app.dispose);
    await app.loadPrefs();
    await app.randomActivityColors(['Run', '\u0000none']);
    expect(saved!['clock'], '24');
    expect(saved!['routeView']['hidden'], ['Run']);
    expect(saved!['routeView']['rainbow'], false);
    expect(saved!['routeView']['colors'], {
      'Ride': '#0000ff',
      'Run': '#df4949',
      '\u0000none': '#45a160',
    });
  });

  testWidgets(
    'connector settings update schedule without resending credentials',
    (tester) async {
      final writes = <Map>[];
      final link = <String, dynamic>{
        'connected': true,
        'athlete': 'Test rider',
        'enabled': true,
        'intervalMin': 60,
        'saveRoutes': true,
        'lastRun': 0,
        'lastOk': 0,
        'lastError': '',
        'totalCount': 12,
      };
      final app = AppState(
        api: SporraApi(
          client: MockClient((request) async {
            expect(request.url.path, '/api/strava');
            if (request.method == 'POST') {
              final patch = jsonDecode(request.body) as Map;
              writes.add(patch);
              link.addAll(Map<String, dynamic>.from(patch));
            }
            return http.Response(jsonEncode({'link': link}), 200);
          }),
        )..server = 'https://example.test',
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectorSettings(app: app, kind: 'strava'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Test rider'), findsOneWidget);
      await tester.tap(find.text('Sync automatically'));
      await tester.pumpAndSettle();
      expect(writes, [
        {'enabled': false},
      ]);
      await tester.tap(find.text('Save activity routes'));
      await tester.pumpAndSettle();
      expect(writes.last, {'saveRoutes': false});
      expect(app.error, isNull);
    },
  );
}
