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
        final pixel =
            ((point.y * scale).round() * frame.image.width +
                (point.x * scale).round()) *
            4;
        expect(
          pixels.getUint8(pixel + 2) - pixels.getUint8(pixel),
          greaterThan(15),
          reason:
              '$detail retains the blue area color after native layer updates',
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
