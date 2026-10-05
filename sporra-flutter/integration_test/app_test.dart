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
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle();
    await tester.tap(signIn);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(MapLibreMap), findsOneWidget);
    final context = tester.element(find.byType(MapLibreMap));
    final state = ProviderScope.containerOf(context).read(appProvider);
    expect(state.error, isNull);
    await state.api.post('/api/import/file', {
      'name': 'qa.gpx',
      'text': '<gpx><trk><trkseg><trkpt lat="46.95" lon="8.28"><time>2024-08-10T09:00:00Z</time></trkpt><trkpt lat="46.951" lon="8.281"><time>2024-08-10T09:01:00Z</time></trkpt><trkpt lat="46.952" lon="8.282"><time>2024-08-10T09:02:00Z</time></trkpt></trkseg></trk></gpx>',
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
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'.toUpperCase()), findsOneWidget);
    expect(find.text('Basemap'), findsOneWidget);
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
