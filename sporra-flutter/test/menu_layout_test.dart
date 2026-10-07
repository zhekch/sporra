import 'dart:convert';

import 'package:flutter_svg/flutter_svg.dart';

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
  testWidgets('Activities opens fullscreen below the phone safe area', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 59);
    addTearDown(tester.view.resetPadding);
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
            '{"routes":[{"id":"1","name":"Morning walk","sport":"Walk","firstAt":1,"lengthM":100,"thumb":"0,100 50,0 100,75|0,0 20,20"}],"distance":"100 m","years":[]}',
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
    expect(find.byType(ActivityMiniature), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Activities').first).dy,
      greaterThanOrEqualTo(59 / tester.view.devicePixelRatio),
    );
    await tester.tap(find.text('By activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Walk · 1'));
    await tester.pumpAndSettle();
    expect(find.text('Morning walk'), findsNothing);
    await tester.tap(find.text('Walk · 1'));
    await tester.pumpAndSettle();
    expect(find.text('Morning walk'), findsOneWidget);
    await tester.tap(find.text('Statistics'));
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
  testWidgets(
    'Coverage defaults to share and country rows show expandable region counts',
    (tester) async {
      final app = AppState(
        api: SporraApi(
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'km2': 110,
                'countryTotal': 200,
                'days': 1,
                'streakDays': 1,
                'years': [],
                'countries': [
                  {'id': 'Large', 'km2': 100, 'pct': 1, 'regionsTotal': 10},
                  {'id': 'Small', 'km2': 10, 'pct': 50, 'regionsTotal': 2},
                ],
                'regions': [
                  {'country': 'Small', 'name': 'Canton', 'km2': 5, 'pct': 25},
                ],
              }),
              200,
            ),
          ),
        )..server = 'https://example.test',
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: webTheme(),
          home: Scaffold(body: statisticsList(app)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widgetList<ChoiceRow>(find.byType(ChoiceRow)).single.value,
        'share',
      );
      await tester.scrollUntilVisible(find.text('Small'), 150);
      expect(find.text('1 of 2 regions'), findsOneWidget);
      expect(find.text('50.0%'), findsOneWidget);
      expect(find.text('Canton'), findsNothing);
      await tester.tap(find.text('Small'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Canton'), 150);
      expect(find.text('25.0%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
