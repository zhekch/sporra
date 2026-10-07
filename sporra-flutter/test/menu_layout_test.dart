import 'package:sporra_flutter/src/native_map.dart';

import 'dart:convert';

import 'package:flutter/cupertino.dart';

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
            '{"routes":[{"id":"1","name":"Morning walk","sport":"Walk","source":"apple-health","firstAt":1,"lengthM":100,"thumb":"0,100 50,0 100,75|0,0 20,20"}],"distance":"100 m","years":[],"sourceLabels":{"apple-health":"Apple Health"}}',
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
    final originalSize = tester.view.physicalSize;
    tester.view.physicalSize =
        const Size(844, 390) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Scaffold).last), const Size(844, 390));
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = originalSize;
    await tester.pumpAndSettle();
    final segment = find.byType(CupertinoSlidingSegmentedControl<int>);
    expect(
      tester
          .getTopLeft(
            find.descendant(of: segment, matching: find.text('Activities')),
          )
          .dx,
      lessThan(
        tester
            .getTopLeft(
              find.descendant(of: segment, matching: find.text('Statistics')),
            )
            .dx,
      ),
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
    await tester.tap(find.text('By app'));
    await tester.pumpAndSettle();
    expect(find.text('Apple health · 1'), findsOneWidget);
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
                  onPressed: () => showSporraSearch(
                    context,
                    app,
                    NativeMapController.libre(_UnusedMap()),
                  ),
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
      expect(
        field.decoration!.hintText,
        'Search for trips, activities or places',
      );
      expect(find.byIcon(CupertinoIcons.search), findsNothing);
      expect(find.byIcon(CupertinoIcons.xmark), findsNothing);
      final popup = tester.getRect(find.byType(Glass));
      final calendar = tester.getRect(find.byTooltip('Calendar'));
      expect(calendar.top - popup.top, 24);
      expect(popup.right - calendar.right, 24);
      expect(
        tester.getRect(find.byType(TextField)).center.dy,
        closeTo(calendar.center.dy, 1),
      );
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
  testWidgets('Settings stays behind iOS picker and embeds sources and sync', (
    tester,
  ) async {
    final app = AppState(
      api: SporraApi(
        client: MockClient((request) async {
          if (request.url.path == '/api/import/link') {
            expect(
              jsonDecode(request.body)['links'],
              'https://www.komoot.com/tour/123456',
            );
            return http.Response('{"imported":20,"routes":1}', 200);
          }
          if (request.url.path == '/api/health') {
            return http.Response('{"app":"sporra","version":"test"}', 200);
          }
          if (request.url.path == '/api/sources') {
            return http.Response(
              '{"sources":[{"key":"gpx","label":"GPX track","cells":20,"routes":2},{"key":"apple-health","cells":5,"routes":1}]}',
              200,
            );
          }
          if (request.url.path == '/api/admin/users') {
            return http.Response(
              '{"users":[{"username":"Alice","admin":true}]}',
              200,
            );
          }
          if (request.url.path == '/api/backup') {
            return http.Response('{"backup":{"files":[]}}', 200);
          }
          return http.Response('{"link":null}', 200);
        }),
      )..server = 'https://example.test',
    );
    app.user = {'admin': true, 'username': 'Alice'};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((ref) => app)],
        child: MaterialApp(
          theme: webTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSettings(context, app),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final appTab = find.widgetWithText(ChoiceChip, 'App settings');
    await tester.ensureVisible(appTab);
    await tester.tap(appTab);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsNothing);
    expect(find.text('Significant changes'), findsOneWidget);
    expect(find.text('Background location'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(app.menuOpen, isTrue);
    await tester.tapAt(const Offset(5, 100));
    await tester.pumpAndSettle();
    final sources = find.widgetWithText(ChoiceChip, 'Sources');
    await tester.ensureVisible(sources);
    await tester.tap(sources);
    await tester.pumpAndSettle();
    expect(find.text('GPX track'), findsOneWidget);
    expect(find.text('Apple health'), findsOneWidget);
    expect(find.text('apple-health'), findsNothing);
    expect(find.text('Manage sources'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
    final sync = find.widgetWithText(ChoiceChip, 'Sync');
    await tester.ensureVisible(sync);
    await tester.tap(sync);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectorSettings), findsNWidgets(2));
    expect(find.text('Strava'), findsOneWidget);
    expect(find.text('Sync connections'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
    final admin = find.widgetWithText(ChoiceChip, 'Administration');
    await tester.ensureVisible(admin);
    await tester.tap(admin);
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    final account = find.widgetWithText(ChoiceChip, 'Backups');
    await tester.ensureVisible(account);
    await tester.tap(account);
    await tester.pumpAndSettle();
    expect(find.text('Back up now on the server'), findsOneWidget);
    expect(find.text('Delete account'), findsNothing);
    expect(find.text('Sign out'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
    final importTab = find.widgetWithText(ChoiceChip, 'Import');
    await tester.ensureVisible(importTab);
    await tester.tap(importTab);
    await tester.pumpAndSettle();
    expect(find.text('Import files'), findsOneWidget);
    expect(find.text('Import Komoot links'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      'https://www.komoot.com/tour/123456',
    );
    await tester.tap(find.text('Import links'));
    await tester.pumpAndSettle();
    expect(find.text('Imported 20 cells and 1 activity.'), findsOneWidget);
    final personal = find.widgetWithText(ChoiceChip, 'Personal');
    await tester.ensureVisible(personal);
    await tester.tap(personal);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Edit'), findsNothing);
    expect(find.text('Delete account'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Account'), findsNothing);
    expect(
      find.ancestor(of: find.text('Sign out'), matching: find.byType(ListView)),
      findsNothing,
    );
    final versions = find.textContaining('iOS version:');
    expect(
      tester.getBottomLeft(find.text('Sign out')).dy,
      lessThan(tester.getTopLeft(versions).dy),
    );
    expect(
      tester.getTopLeft(versions).dy -
          tester.getBottomLeft(find.text('Sign out')).dy,
      lessThan(50),
    );
    expect(find.text('MANUAL EDIT'), findsOneWidget);
    expect(find.text('Edit on the map'), findsOneWidget);
    final originalSize = tester.view.physicalSize;
    tester.view.physicalSize =
        const Size(844, 390) * tester.view.devicePixelRatio;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Scaffold).last), const Size(844, 390));
    tester.view.physicalSize = originalSize;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
