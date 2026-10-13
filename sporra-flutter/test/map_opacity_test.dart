import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  testWidgets('opacity bar can be dragged to true zero and full opacity', (
    tester,
  ) async {
    double opacity = 0.3;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, set) => MapOpacitySlider(
              value: opacity,
              onChanged: (value) => set(() => opacity = value),
              onChangeEnd: (_) {},
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(Slider));
    final gesture = await tester.startGesture(rect.center);
    await gesture.moveTo(rect.centerLeft - const Offset(20, 0));
    await tester.pump();
    expect(opacity, 0);
    expect(find.text('0%'), findsOneWidget);
    await gesture.moveTo(rect.centerRight + const Offset(20, 0));
    await tester.pump();
    expect(opacity, 1);
    expect(find.text('100%'), findsOneWidget);
    await gesture.up();
  });

  test(
    'opacity retains defaults and saves independent full-range values',
    () async {
      Map<String, dynamic> stored = {'clock': '24'};
      AppState createApp() => AppState(
        api: SporraApi(
          client: MockClient((request) async {
            if (request.method == 'POST') {
              stored = Map<String, dynamic>.from(
                jsonDecode(request.body)['prefs'],
              );
            }
            return http.Response(jsonEncode({'prefs': stored}), 200);
          }),
        )..server = 'https://example.test',
      );
      final app = createApp();
      addTearDown(app.dispose);
      await app.loadPrefs();
      expect(app.mapOpacity, 0.3);
      app.accent = '#60acff80';
      expect(app.mapOpacity, closeTo(0.3 * 128 / 255, 1e-9));
      expect(Uri.splitQueryString(app.renderQuery(0))['accent'], '#60acff');
      app.mapOpacity = 1;
      expect(app.groundOpacity, 1);
      await app.saveAppearance();
      for (final mode in ['visits', 'oldest', 'type']) {
        app.mode = mode;
        expect(app.mapOpacity, 0.5);
      }
      app.mode = 'visits';
      app.mapOpacity = 0;
      await app.saveAppearance();
      expect(stored['clock'], '24');
      final restored = createApp();
      addTearDown(restored.dispose);
      await restored.loadPrefs();
      expect(restored.mode, 'visits');
      expect(restored.groundOpacity, 0);
      restored.mode = 'flat';
      expect(restored.groundOpacity, 1);
      restored.ground = false;
      expect(restored.groundOpacity, 0);
      expect(restored.mapOpacity, 1);
    },
  );

  for (final mode in ['flat', 'visits', 'oldest', 'type']) {
    testWidgets('opacity slider sits below the $mode color controls', (
      tester,
    ) async {
      final app = AppState()..mode = mode;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appProvider.overrideWith((ref) => app)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showMenuSheet(context, app, () {}, null),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(MapOpacitySlider));
      await tester.pumpAndSettle();
      expect(find.text(mode == 'flat' ? '30%' : '50%'), findsOneWidget);
      if (mode != 'type') {
        final previous = find.text(switch (mode) {
          'flat' => 'Map colour',
          'visits' => 'Rare',
          _ => 'Long ago',
        });
        expect(
          tester.getTopLeft(find.byType(MapOpacitySlider)).dy,
          greaterThan(tester.getBottomLeft(previous).dy),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('color picker saves RGB without an opacity control', (
    tester,
  ) async {
    String? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  chosen = await chooseColor(context, '#60acff80'),
              child: const Text('Colour'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Colour'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(chosen, '#60acff');
  });
}
