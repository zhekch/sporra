import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:sporra_flutter/main.dart' as app;
import 'package:sporra_flutter/src/state.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/native.g.dart';
import 'package:sporra_flutter/src/blob.dart';
import 'package:sporra_flutter/src/map_screen.dart';
import 'package:sporra_flutter/src/sheets.dart';

import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native sign-in, cells, menus and edit undo', (tester) async {
    final api = SporraApi()..server = 'http://127.0.0.1:3209';
    try {
      await api.post('/api/register', {
        'username': 'flutterqa',
        'password': 'flutter-test-password',
      });
    } catch (_) {}
    await SporraNative().signOut();
    app.main();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 30),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Server address'),
      'http://127.0.0.1:3209',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Username'),
      'flutterqa',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'flutter-test-password',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 30),
    );
    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 30),
    );
    await tester.tap(signIn);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(MapLibreMap), findsOneWidget);
    final context = tester.element(find.byType(MapLibreMap));
    final state = ProviderScope.containerOf(context).read(appProvider);
    expect(state.error, isNull);
    // A failed or interrupted run may leave the deliberate overlap fixture.
    // Reset this disposable account before testing the single-route hit path.
    for (final route in (await state.api.get('/api/routes'))['routes']) {
      await state.api.post('/api/routes/delete', {'id': route['id']});
    }
    await state.api.post('/api/prefs', {'prefs': {}});
    await state.loadPrefs();

    await state.api.post('/api/import/file', {
      'name': 'qa.gpx',
      'text': '<gpx><trk><trkseg><trkpt lat="46.95" lon="8.28"><ele>500</ele><time>2024-08-11T09:00:00Z</time></trkpt><trkpt lat="46.951" lon="8.281"><ele>525</ele><time>2024-08-11T09:01:00Z</time></trkpt><trkpt lat="46.952" lon="8.282"><ele>515</ele><time>2024-08-11T09:02:00Z</time></trkpt></trkseg></trk></gpx>',
    });
    state.changed();
    await tester.pump(const Duration(seconds: 3));
    final first = await state.api.get('/api/render/cells');
    expect(first['rows'], isA<List>());
    final before = (await state.api.get('/api/cells'))['rows'].length;
    final edited = await state.api.post('/api/render/brush', {
      'level': 0,
      'size': 1,
      'action': 'paint',
      'points': [
        [8.28, 46.95],
      ],
    });
    expect(
      (await state.api.get('/api/cells'))['rows'].length,
      greaterThanOrEqualTo(before),
    );
    await state.api.post('/api/cells/mutate', {
      'remove': edited['undo']['remove'],
    });
    await state.api.post('/api/cells/restore', {
      'rows': edited['undo']['rows'],
    });
    expect((await state.api.get('/api/cells'))['rows'].length, before);
    final dynamic screen = tester.state(find.byType(MapScreen));
    final MapLibreMapController controller = screen.map;
    await controller.moveCamera(
      CameraUpdate.newLatLngZoom(const LatLng(46.95, 8.28), 7),
    );
    for (final detail in ['region', 'country', 'continent', 'auto']) {
      state.detail = detail;
      state.changed();
      await tester.pump();
      for (var attempt = 0; attempt < 400; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        if (screen.loaded &&
            !screen.refreshing &&
            !screen.pending &&
            (detail == 'auto' || screen.layers.contains('areas-fill'))) {
          break;
        }
      }
      expect(screen.loaded, isTrue, reason: 'native basemap style has loaded');
      expect(screen.refreshing, isFalse);
      await tester.runAsync(() async {
        await screen.refresh();
      });
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();
      expect(
        screen.mapError,
        isNull,
        reason: '$detail must load on MapLibre Native',
      );
      if (detail == 'country') {
        final details = screen.tap(const LatLng(46.95, 8.28));
        expect(screen.placeInfo?['visited'], isTrue);
        expect(
          screen.placeInfo?['covered'],
          greaterThan(0),
          reason: 'coverage is immediate from viewport facts',
        );
        expect(screen.placeInfo?['geometry'], isNotNull);
        await tester.runAsync(() => details);
        await tester.pumpAndSettle();
        await tester.runAsync(() => screen.updatePlaceOutline());
        expect(
          await controller.querySourceFeatures('place-selection', null, null),
          isNotEmpty,
        );
        expect(find.textContaining('Ground covered'), findsOneWidget);
        await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
          'parity-place-country',
        );
        await tester.tap(find.byTooltip('Close place'));
        await tester.pumpAndSettle();
      }
      if (detail != 'auto') {
        final point = await controller.toScreenLocation(
          const LatLng(46.95, 8.28),
        );
        final areas = await controller.queryRenderedFeatures(
          math.Point(point.x.toDouble(), point.y.toDouble()),
          ['areas-fill'],
          null,
        );
        final areaBytes = await IntegrationTestWidgetsFlutterBinding.instance
            .takeScreenshot('parity-$detail');
        await File('${Directory.systemTemp.path}/sporra-parity-$detail.png')
            .writeAsBytes(areaBytes);
        final codec = await ui.instantiateImageCodec(
          Uint8List.fromList(areaBytes),
        );
        final frame = await codec.getNextFrame();
        final pixels = (await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final scale = frame.image.width / screen.mapSize.width;
        // Basemap roads/labels and the orange activity can cover individual
        // pixels. Inspect the surrounding ground as well as querying the fill.
        var bluePixels = 0;
        final cx = (point.x * scale).round(), cy = (point.y * scale).round();
        for (var y = cy - 24; y <= cy + 24; y++) {
          for (var x = cx - 24; x <= cx + 24; x++) {
            if (x < 0 ||
                y < 0 ||
                x >= frame.image.width ||
                y >= frame.image.height) {
              continue;
            }
            final pixel = (y * frame.image.width + x) * 4;
            if (pixels.getUint8(pixel + 2) - pixels.getUint8(pixel) > 15) {
              bluePixels++;
            }
          }
        }
        expect(
          bluePixels,
          greaterThan(20),
          reason:
              '$detail retains blue ground around the activity after native layer updates',
        );
        frame.image.dispose();
        codec.dispose();
        expect(
          areas,
          isNotEmpty,
          reason: '$detail fill is visible over the imported activity',
        );
      }
    }
    state.detail = 'auto';
    await controller.moveCamera(
      CameraUpdate.newLatLngZoom(const LatLng(46.951, 8.281), 14),
    );
    state.changed();
    await tester.pump();
    await tester.runAsync(() async {
      await screen.refresh();
      for (var i = 0; i < 400 && (screen.refreshing || screen.pending); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    final routePixel = await controller.toScreenLocation(
      const LatLng(46.951, 8.281),
    );
    Future<void>? routeTap;
    await tester.runAsync(() async {
      routeTap = screen.tap(
        const LatLng(46.951, 8.281),
        pixel: math.Point<double>(
          routePixel.x.toDouble() + 6,
          routePixel.y.toDouble(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    if (find.text('Choose an activity').evaluate().isNotEmpty) {
      await tester.tap(find.text('qa').last);
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() => routeTap!);
    await tester.pumpAndSettle();
    expect(
      state.activity,
      isNotNull,
      reason: 'a tap beside the hairline selects its activity',
    );
    expect(
      screen.placeInfo,
      isNull,
      reason: 'the same tap does not also open a place card',
    );
    final metricFeatures = await controller.querySourceFeatures(
      'activity-metric',
      null,
      null,
    );
    expect(metricFeatures, isNotEmpty);
    expect(screen.layers.contains('activity-metric-casing'), isTrue);
    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'parity-speed',
    );
    state.closeActivity();
    await tester.pump();
    // Check the visible response before the HTTP details request completes.
    final infoFuture = screen.tap(const LatLng(46.951, 8.281));
    expect(screen.placeInfo?['visited'], isTrue);
    expect(screen.placeInfo?['hits'], greaterThan(0));
    await tester.runAsync(() => infoFuture);
    await tester.pumpAndSettle();
    expect(find.text('You have been here'), findsOneWidget);
    await tester.tap(find.byTooltip('Close place'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => state.selectTrack(day: '2024-08-11'));
    await tester.pump();
    await tester.runAsync(() async {
      await screen.refresh();
      for (var i = 0; i < 400 && (screen.refreshing || screen.pending); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    final tripFeatures = await controller.querySourceFeatures(
      'trip',
      null,
      null,
    );
    expect(
      tripFeatures,
      isNotEmpty,
      reason: 'day selection draws yellow dots and lines',
    );
    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'parity-day',
    );
    await tester.drag(
      find.byKey(const ValueKey('track-2024-08-11')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(
      state.track,
      isNull,
      reason: 'vertical swipe dismisses the selection',
    );
    state.clearTrack();
    await tester.pumpAndSettle();
    final existing =
        ((await state.api.get('/api/routes?geom=1'))['routes'] as List).first;
    await state.api.post('/api/routes', {
      'source': 'gpx',
      'routes': [
        {
          ...existing,
          'id': null,
          'name': 'Overlapping ride',
          'key': 'flutter-parity-overlap',
          'firstAt': (existing['firstAt'] as num) + 86400,
          'lastAt': (existing['lastAt'] as num) + 86400,
        },
      ],
    });
    state.changed();
    await controller.moveCamera(
      CameraUpdate.newLatLngZoom(const LatLng(46.951, 8.281), 14),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await screen.refresh();
      for (var i = 0; i < 400 && (screen.refreshing || screen.pending); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    final overlapPixel = await controller.toScreenLocation(
      const LatLng(46.951, 8.281),
    );
    Future<void>? chooser;
    await tester.runAsync(() async {
      chooser = screen.tap(
        const LatLng(46.951, 8.281),
        pixel: math.Point<double>(
          overlapPixel.x.toDouble(),
          overlapPixel.y.toDouble(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('Choose an activity'), findsOneWidget);
    expect(find.text('Overlapping ride'), findsOneWidget);
    expect(find.byTooltip('Search'), findsNothing);
    final dots = tester
        .widgetList<ColorDot>(find.byType(ColorDot))
        .map((dot) => dot.hex)
        .toSet();
    expect(
      dots.length,
      2,
      reason: 'overlap activities have distinct web palette colours',
    );
    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'parity-overlap',
    );
    await tester.tap(find.text('Overlapping ride'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => chooser!);
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && state.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    expect(state.activity?['route']['name'], 'Overlapping ride');
    expect(state.selectedRoute, state.activity!['route']['id']);
    expect(find.text('Focus'), findsOneWidget);
    expect(find.text('More info'), findsOneWidget);
    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(state.selectedRoute, isNull);
    expect(state.activity, isNotNull);
    final selectedWorkout = state.activity!['route']['id'];
    for (final delta in [500.0, -500.0]) {
      await tester.drag(
        find.byKey(ValueKey('workout-${state.activity!['route']['id']}')),
        Offset(delta, 0),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && state.busy; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      });
      await tester.pumpAndSettle();
      expect(state.activity!['route']['id'] == selectedWorkout, delta < 0);
    }
    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'parity-workout-banner',
    );
    await tester.drag(
      find.byKey(ValueKey('workout-${state.activity!['route']['id']}')),
      const Offset(500, 0),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && state.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    expect(state.activity, isNotNull);
    expect(
      state.activity!['route']['id'],
      isNot(selectedWorkout),
      reason: 'swipe goes to the previous workout',
    );
    expect(find.byTooltip('Close workout'), findsNothing);
    state.closeActivity();
    await tester.pumpAndSettle();

    await state.run(
      () => state.saveRouteView({
        'colors': {'Walking': '#ff000080'},
      }),
    );
    final routeData = await state.api.get('/api/render/routes');
    expect(routeData['features'], isNotEmpty);
    expect(tester.takeException(), isNull);
    final routes = (await state.api.get('/api/routes'))['routes'] as List;
    await state.openActivity(routes.first['id']);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('Elevation'), findsOneWidget);
    expect(find.byTooltip('Close activity'), findsOneWidget);
    final graphBytes = await IntegrationTestWidgetsFlutterBinding.instance
        .takeScreenshot('parity-activity');
    await File('${Directory.systemTemp.path}/sporra-parity-activity.png')
        .writeAsBytes(graphBytes);
    state.scrubActivity(1);
    await tester.pump();
    await tester.runAsync(() async {
      await screen.updateActivityFocus(state);
    });
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    final cursor = await controller.querySourceFeatures(
      'activity-cursor',
      null,
      null,
    );
    expect(
      cursor,
      isNotEmpty,
      reason: 'graph scrubbing places a marker on the map',
    );
    await tester.tap(find.text('Elevation'));
    await tester.pumpAndSettle();
    expect(state.activityMetric, 'elev');
    state.closeActivity();
    await tester.pumpAndSettle();
    state.rail = true;
    state.changed();
    await tester.pump();
    await tester.runAsync(() async {
      await screen.refresh();
      for (var i = 0; i < 400 && (screen.refreshing || screen.pending); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    expect(
      screen.mapError,
      isNull,
      reason: 'train track numeric properties load natively',
    );
    expect(screen.sources.contains('rail-ready'), isTrue);
    state.airports = true;
    state.airportGroups.addAll(['airfields', 'helipads', 'closed']);
    state.changed();
    await tester.pump();
    await tester.runAsync(() async {
      await screen.refresh();
      for (var i = 0; i < 400 && (screen.refreshing || screen.pending); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    expect(
      screen.mapError,
      isNull,
      reason: 'all airport group layers and labels load natively',
    );
    for (final group in ['airline', 'airfields', 'helipads', 'closed']) {
      expect(screen.sources.contains('airports-$group'), isTrue);
    }
    expect(
      screen.layers.contains('airport-pins-sporra-air-large-label'),
      isTrue,
    );
    final airportBytes = await IntegrationTestWidgetsFlutterBinding.instance
        .takeScreenshot('parity-airports');
    await File('${Directory.systemTemp.path}/sporra-parity-airports.png')
        .writeAsBytes(airportBytes);
    state.airports = false;

    state.rail = false;
    state.changed();
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 30),
    );
    expect(find.text('Appearance'.toUpperCase()), findsOneWidget);
    expect(find.text('Basemap'), findsOneWidget);
    final bytes = await IntegrationTestWidgetsFlutterBinding.instance
        .takeScreenshot('parity-menu');
    await File('${Directory.systemTemp.path}/sporra-parity-menu.png')
        .writeAsBytes(bytes);
    expect(tester.takeException(), isNull);
    expect(
      find.byTooltip('Search'),
      findsNothing,
      reason: 'map controls are hidden while menu is open',
    );
    showSettings(screen.context, state);
    await tester.pumpAndSettle();
    expect(find.text('Appearance'.toUpperCase()), findsNothing);
    expect(find.byType(ChoiceChip), findsNWidgets(6));
    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'parity-settings-personal',
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'Map layers'));
    await tester.pumpAndSettle();
    expect(find.text('Mapbox public token'), findsOneWidget);
    expect(find.byTooltip('Search'), findsNothing);
    expect(find.byTooltip('Menu'), findsNothing);
    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'parity-settings-map',
    );
    Navigator.of(screen.context).pop();
    await tester.pumpAndSettle();
    state.trackDay = '2026-08-11';
    Future<DateTime?>? calendar;
    await tester.runAsync(() async {
      calendar = chooseDay(screen.context, state);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
    expect(find.text('August 2026'), findsOneWidget);
    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'parity-calendar',
    );
    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();
    expect(await calendar!, DateTime(2026, 8, 11));
    state.trackDay = null;
    await tester.pump(const Duration(seconds: 8));
    final painter = BlobPainter();
    final sample = await state.api.get('/api/render/cells?level=5');
    final sheet = await painter.paint(
      Map<String, dynamic>.from(sample),
      [7.5, 46.5, 9, 47.5],
      256,
      256,
      false,
    );
    expect(sheet.bytes.length, greaterThan(100));
    await state.initialize();
    expect(
      state.user?['username'],
      'flutterqa',
      reason: 'a cold session check retains native sign-in',
    );
    await state.signOut();
  });
}
