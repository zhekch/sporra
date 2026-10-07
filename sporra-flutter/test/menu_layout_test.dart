import 'dart:convert';

import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:sporra_flutter/src/appearance.dart';
import 'package:sporra_flutter/src/calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:sporra_flutter/src/state.dart';

class _UnusedMap extends Fake implements MapLibreMapController {}

void main() {
  testWidgets('Routes and statistics opens fullscreen on routes', (
    tester,
  ) async {
    final app = AppState(
      api: SporraApi(
        client: MockClient((request) async {
          if (request.url.path == '/api/stats') {
            return http.Response(
              '{"countries":[],"regions":[],"km2":0,"countryTotal":200,"days":0,"streakDays":0,"years":[]}',
              200,
            );
          }
          return http.Response(
            '{"routes":[{"id":"1","name":"Morning walk","sport":"Walk","firstAt":1,"lengthM":100,"geom":[[[8,47],[8.1,47.1],[8.2,47.05]]]}],"distance":"100 m","years":[]}',
            200,
          );
        }),
      )..server = 'https://example.test',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((ref) => app)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showStats(context, app),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final scaffold = find.byType(Scaffold).last;
    expect(
      tester.getSize(scaffold),
      tester.view.physicalSize / tester.view.devicePixelRatio,
    );
    expect(find.text('Morning walk'), findsOneWidget);
    expect(find.byType(RouteMiniature), findsOneWidget);
    await tester.tap(find.text('Ground'));
    await tester.pumpAndSettle();
    expect(find.text('Ground covered'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Search header switches trips and calendar without reusing data',
    (tester) async {
      final app = AppState(
        api: SporraApi(
          client: MockClient((request) async {
            if (request.url.path == '/api/days') {
              return http.Response('{"days":{}}', 200);
            }
            return http.Response(
              jsonEncode({
                'trips': [
                  {
                    'id': 'visible',
                    'name': 'Visible trip',
                    'start': 1723280400,
                    'end': 1723366800,
                  },
                  {
                    'id': 'hidden',
                    'name': 'Hidden trip',
                    'start': 1723280400,
                    'end': 1723366800,
                  },
                ],
              }),
              200,
            );
          }),
        )..server = 'https://example.test',
      );
      app.prefs['hiddenTrips'] = ['hidden'];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appProvider.overrideWith((ref) => app)],
          child: MaterialApp(
            theme: webTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSporraSearch(context, app, _UnusedMap()),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Search'), findsNothing);
      expect(find.text('Visible trip'), findsOneWidget);
      expect(find.text('Hidden trip'), findsNothing);
      expect(find.textContaining('hidden trips'), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.border, InputBorder.none);
      await tester.tap(find.byTooltip('Calendar'));
      await tester.pumpAndSettle();
      expect(find.byType(VisitCalendar), findsOneWidget);
      expect(find.text('Mon'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Calendar'));
      await tester.pumpAndSettle();
      expect(find.text('Visible trip'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
