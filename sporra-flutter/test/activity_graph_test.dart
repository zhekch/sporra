import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/activity_graph.dart';
import 'package:sporra_flutter/src/appearance.dart';
import 'package:sporra_flutter/src/state.dart';
import 'package:sporra_flutter/src/map_screen.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

final graph = <String, dynamic>{
  'metric': 'speed',
  'min': 1,
  'max': 3,
  'maxX': 100,
  'minLabel': '3.6 km/h',
  'maxLabel': '10.8 km/h',
  'ticks': <dynamic>[],
  'runs': [
    [
      {'i': 0, 'x': 0, 'y': 1, 'color': null, 'label': '3.6 km/h'},
      {
        'i': 1,
        'x': 25,
        'y': 2,
        'color': 'rgb(232,184,42)',
        'label': '7.2 km/h',
      },
    ],
    [
      {'i': 2, 'x': 75, 'y': 2, 'color': null, 'label': '7.2 km/h'},
      {
        'i': 3,
        'x': 100,
        'y': 3,
        'color': 'rgb(36,158,74)',
        'label': '10.8 km/h',
      },
    ],
  ],
};
void main() {
  testWidgets('Focus sends duration and measured insets to the native camera', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl_987');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    final platform = MapLibreMethodChannel();
    await platform.initPlatform(987);
    final controller = MapLibreMapController(
      maplibrePlatform: platform,
      annotationOrder: [],
      annotationConsumeTapEvents: [],
    );
    goTo(controller, {
      'bounds': [7, 46, 8, 47],
    }, padding: const EdgeInsets.fromLTRB(24, 139, 24, 466));
    await tester.pump();
    final arguments =
        calls.singleWhere((c) => c.method == 'camera#animate').arguments as Map;
    expect(arguments['duration'], 450);
    expect((arguments['cameraUpdate'] as List).skip(2).toList(), [
      24.0,
      139.0,
      24.0,
      466.0,
    ]);
    controller.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  testWidgets('activity card and main menu share the same clip and border', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final app = AppState()
      ..activityMetric = 'speed'
      ..selectedRoute = 1
      ..activity = {
        'route': {
          'id': 1,
          'name': 'Evening walk',
          'sport': 'Walking',
          'firstAt': 1789747200,
          'elevUp': 9,
        },
        'summary': {
          'distance': '1.4 km',
          'duration': '1 h',
          'averageSpeed': '1.4 km/h',
        },
        'graphs': {
          'speed': graph,
          'elev': {...graph, 'metric': 'elev'},
        },
      };
    addTearDown(app.dispose);
    late BuildContext context;
    final output = Platform.environment['SPORRA_CORNER_PREVIEW'];
    if (output != null) {
      await tester.runAsync(() async {
        final bytes = await File('/System/Library/Fonts/SFNS.ttf')
            .readAsBytes();
        final loader = FontLoader('.SF Pro Text')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
        final fallback = FontLoader('Ahem')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await fallback.load();
        final icons = FontLoader('packages/cupertino_icons/CupertinoIcons')
          ..addFont(
            rootBundle.load(
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
            ),
          );
        await icons.load();
      });
    }
    var focused = 0;
    final preview = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(
          key: preview,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: webTheme(menuRadius: 43),
            home: Builder(
              builder: (c) {
                context = c;
                return Scaffold(
                  body: SafeArea(
                    bottom: false,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 430),
                          child: Glass(
                            child: ActivityCard(
                              app: app,
                              onZoom: () => focused++,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    BorderRadiusGeometry clip() => tester
        .widget<ClipRSuperellipse>(
          find.descendant(
            of: find.byType(Glass).last,
            matching: find.byType(ClipRSuperellipse),
          ),
        )
        .borderRadius;
    RoundedSuperellipseBorder border() =>
        (tester
                        .widget<DecoratedBox>(
                          find
                              .descendant(
                                of: find.byType(Glass).last,
                                matching: find.byWidgetPredicate(
                                  (w) =>
                                      w is DecoratedBox &&
                                      w.decoration is ShapeDecoration,
                                ),
                              )
                              .first,
                        )
                        .decoration
                    as ShapeDecoration)
                .shape
            as RoundedSuperellipseBorder;
    expect(find.text('Zoom to activity'), findsNothing);
    expect(find.text('Along the activity'), findsNothing);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    final actions = find.descendant(
      of: find.byType(ActivityCard),
      matching: find.byType(FilledButton),
    );
    expect(actions, findsNWidgets(3));
    expect(844 - tester.getBottomLeft(find.byType(Glass)).dy, 12);
    expect(
      tester.getTopLeft(find.text('Evening walk')).dy -
          tester.getTopLeft(find.byType(Glass)).dy,
      22,
    );
    for (final button in tester.widgetList<FilledButton>(actions)) {
      final shape =
          button.style!.shape!.resolve({}) as RoundedSuperellipseBorder;
      expect(shape.borderRadius, BorderRadius.circular(29));
    }

    final sizes = [for (var i = 0; i < 3; i++) tester.getSize(actions.at(i))];
    for (final size in sizes) {
      expect(size.width, closeTo(sizes.first.width, 0.01));
      expect(size.height, 44);
    }
    expect(
      tester.getTopLeft(find.text('Walking · 18.09.2026')).dy -
          tester.getBottomLeft(find.text('Evening walk')).dy,
      closeTo(2, 0.01),
    );
    await tester.tap(find.text('Focus'));
    expect(focused, 1);
    await tester.tap(find.text('Show all'));
    expect(app.selectedRoute, isNull);
    final activityCorners = clip();
    expect(activityCorners, BorderRadius.circular(43));
    expect(border().borderRadius, activityCorners);
    if (output != null) {
      await tester.runAsync(() async {
        final boundary =
            preview.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    showMenuSheet(context, app, () {}, null);
    await tester.pumpAndSettle();
    expect(clip(), activityCorners);
    expect(border().borderRadius, activityCorners);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'activity banner navigates horizontal swipes without moving the map',
    (tester) async {
      final steps = <int>[];
      var dismissed = 0, mapDrags = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (_) => mapDrags++,
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: ActivityBanner(
                    name: 'Evening walk',
                    onStep: steps.add,
                    onDismiss: () => dismissed++,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Evening walk'), findsOneWidget);
      expect(find.text('Walking'), findsNothing);
      final original = tester.getTopLeft(find.text('Evening walk'));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ActivityBanner)),
      );
      await gesture.moveBy(const Offset(-70, 5));
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('Evening walk')).dx,
        lessThan(original.dx - 40),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Evening walk')), original);
      steps.clear();
      await tester.drag(find.byType(ActivityBanner), const Offset(-120, 15));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ActivityBanner), const Offset(120, -15));
      await tester.pumpAndSettle();
      expect(steps, [1, -1]);
      expect(mapDrags, 0);
      expect(dismissed, 0);
      await tester.drag(find.byType(ActivityBanner), const Offset(5, 90));
      await tester.pumpAndSettle();
      expect(dismissed, 1);
      expect(steps, [1, -1]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('graph scrubbing wins vertical card dismissal and scrolling', (
    tester,
  ) async {
    final app = AppState()
      ..activityMetric = 'speed'
      ..activity = {
        'route': {'id': 1, 'name': 'Walk', 'sport': 'Walking', 'firstAt': 0},
        'summary': {'distance': '1 km'},
        'graphs': {'speed': graph, 'elev': null},
      };
    addTearDown(app.dispose);
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: webTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              height: 360,
              child: Dismissible(
                key: const ValueKey('activity'),
                direction: DismissDirection.vertical,
                onDismissed: (_) => dismissed = true,
                child: Glass(
                  child: ActivityCard(app: app, onZoom: () {}),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final graphBox = find.descendant(
      of: find.byType(ActivityGraph),
      matching: find.byWidgetPredicate((w) => w is SizedBox && w.height == 72),
    );
    final origin = tester.getTopLeft(find.byType(ActivityCard));
    final gesture = await tester.startGesture(tester.getCenter(graphBox));
    await gesture.moveBy(const Offset(35, 55));
    await tester.pump();
    expect(app.activitySample, isNotNull);
    expect(tester.getTopLeft(find.byType(ActivityCard)), origin);
    await gesture.moveBy(const Offset(15, 35));
    await tester.pump();
    expect(tester.getTopLeft(find.byType(ActivityCard)), origin);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(dismissed, isFalse);
    expect(tester.takeException(), isNull);
  });

  test('native layer patches retain omitted style properties', () {
    expect(
      const LayerPatch(FillLayerProperties(fillOpacity: .3))
          .toJson(skipNulls: false),
      {'fill-opacity': .3},
    );
    expect(
      const LayerPatch(LineLayerProperties(visibility: 'none'))
          .toJson(skipNulls: false),
      {'visibility': 'none'},
    );
  });
  testWidgets('scrubbing selects the nearest recorded sample across a gap', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: webTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ActivityGraph(graph: graph, onScrub: (i) => selected = i),
          ),
        ),
      ),
    );
    final paint = find.descendant(
      of: find.byType(ActivityGraph),
      matching: find.byWidgetPredicate((w) => w is SizedBox && w.height == 72),
    );
    final rect = tester.getRect(paint);
    await tester.tapAt(Offset(rect.left + rect.width * 0.8, rect.center.dy));
    expect(selected, 2);
    expect(find.text('10.8 km/h'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('missing trace gives an explicit empty state', (tester) async {
    final app = AppState()
      ..activity = {
        'route': {
          'id': 1,
          'name': 'Undated walk',
          'sport': 'Walking',
          'firstAt': 0,
        },
        'summary': {'distance': '1 km'},
        'graphs': {'speed': null, 'elev': null},
      };
    await tester.pumpWidget(
      MaterialApp(
        theme: webTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 430,
            child: ActivityCard(app: app, onZoom: () {}),
          ),
        ),
      ),
    );
    expect(find.byType(ActivityGraph), findsNothing);
    expect(
      find.text('This activity has no recorded speed or elevation data.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    app.dispose();
  });
}
