import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/closing_blur.dart';
import 'package:sporra_flutter/src/sheets.dart' show Glass, panel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sporra_flutter/src/state.dart';

void main({
  Future<void> Function(WidgetTester tester)? onFeatheredFrame,
  Future<ByteData> Function(
    WidgetTester tester,
    RenderRepaintBoundary boundary,
  )?
  nativePixels,
}) {
  testWidgets('closing keyframes grow and cancelled drag settles sharp', (
    tester,
  ) async {
    final animation = AnimationController(vsync: tester);
    addTearDown(animation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ClosingBlur(animation: animation, child: const Text('Menu')),
      ),
    );
    ImageFiltered filter() =>
        tester.widget<ImageFiltered>(find.byType(ImageFiltered));
    animation.value = 0.5;
    await tester.pump();
    expect(filter().enabled, isFalse);
    animation.value = 1;
    await tester.pump();
    animation.value = 0.65;
    await tester.pump();
    expect(filter().enabled, isTrue);
    expect(filter().imageFilter.toString(), contains('2.0'));
    animation.value = 0.3;
    await tester.pump();
    expect(filter().imageFilter.toString(), contains('8.0'));
    animation.value = 0;
    await tester.pump();
    expect(filter().imageFilter.toString(), contains('18.0'));
    animation.value = 1;
    await tester.pump();
    expect(filter().enabled, isFalse);
  });

  testWidgets('closing blur feathers the surface edge into transparency', (
    tester,
  ) async {
    final animation = AnimationController(vsync: tester, value: 1);
    addTearDown(animation.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 120,
              height: 120,
              child: Center(
                child: ClosingBlur(
                  filterChild: false,
                  animation: animation,
                  child: const Glass(child: SizedBox(width: 60, height: 60)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Native window capture and image decoding finish outside the test clock.
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    animation.value = 0.3;
    await tester.pump();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final pixels = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!;
    });
    int alpha(int x) => pixels!.getUint8((60 * 120 + x) * 4 + 3);
    // The original surface spans x=30..89. Its edge should fade on both sides.
    expect(alpha(25), greaterThan(0));
    expect(alpha(30), lessThan(138));
    expect(alpha(60), greaterThan(120));
    animation.value = 1;
    await tester.pump();
  });

  testWidgets('live glass boundary feathers over a bright patterned backdrop', (
    tester,
  ) async {
    final key = GlobalKey();
    final sigma = ValueNotifier(0.0);
    addTearDown(sigma.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 320,
              height: 240,
              child: Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(color: Colors.white)),
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 25,
                    height: 30,
                    child: ColoredBox(color: Colors.orange),
                  ),
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 25,
                    height: 30,
                    child: ColoredBox(color: Colors.blue),
                  ),
                  const Positioned(
                    left: 120,
                    top: 105,
                    width: 80,
                    height: 30,
                    child: ColoredBox(color: Colors.black),
                  ),
                  Center(
                    child: ValueListenableBuilder<double>(
                      valueListenable: sigma,
                      builder: (context, value, child) =>
                          ClosingBlurScope(sigma: value, child: child!),
                      child: const Glass(
                        child: SizedBox(width: 200, height: 120),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    Future<ByteData> readPixels() async => nativePixels != null
        ? await nativePixels(tester, boundary)
        : (await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            image.dispose();
            return bytes!;
          }))!;
    var pixels = await readPixels();
    int red(int x, [int y = 120]) => pixels.getUint8((y * 320 + x) * 4);
    final openPixels = pixels.buffer.asUint8List();
    final openEdge = red(60);
    final openCenter = red(100);
    sigma.value = 0.05;
    await tester.pump();
    pixels = await readPixels();
    expect((red(60) - openEdge).abs(), lessThan(8));
    expect((red(100) - openCenter).abs(), lessThan(3));
    sigma.value = 8;
    await tester.pump();
    pixels = await readPixels();
    if (onFeatheredFrame != null) await onFeatheredFrame(tester);
    // At the left edge (x=60), the blurred backdrop must blend into the map,
    // rather than leaving a sharp line while only the text is blurred.
    expect(red(60), greaterThan(180));
    expect(red(64), lessThan(red(60)));
    expect(red(68), lessThan(red(64)));
    expect(red(100), lessThan(160));
    // The black map detail must stay blurred behind the glass, even though
    // the edge mask uses a separate compositing layer.
    expect(red(150), greaterThan(70));
    for (var x = 57; x < 90; x++) {
      expect((red(x + 1) - red(x)).abs(), lessThan(24));
    }
    expect(red(64, 64), greaterThan(210));
    expect(red(84, 84), lessThan(red(74, 74)));

    final middleEdge = red(68);
    sigma.value = 18;
    await tester.pump();
    pixels = await readPixels();
    expect(red(68), greaterThan(middleEdge));
    sigma.value = 0;
    await tester.pump();
    pixels = await readPixels();
    expect(pixels.buffer.asUint8List(), orderedEquals(openPixels));
  });

  testWidgets('glass panel survives a tap and cancelled drag, then dismisses', (
    tester,
  ) async {
    final app = AppState();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((ref) => app)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    panel(context, 'Menu', const SizedBox(height: 220)),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(app.menuOpen, isTrue);
    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(tester.getCenter(find.text('Menu')));
    await drag.moveBy(const Offset(0, 20));
    await tester.pump();
    await drag.moveBy(const Offset(0, 30));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await drag.up();
    await tester.pumpAndSettle();
    expect(find.text('Menu'), findsOneWidget);
    expect(app.menuOpen, isTrue);
    await tester.fling(find.text('Menu'), const Offset(0, 350), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Menu'), findsNothing);
    expect(app.menuOpen, isFalse);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Glass),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Menu'), findsNothing);
    expect(app.menuOpen, isFalse);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 120));
    await tester.pumpAndSettle();
    expect(find.text('Menu'), findsNothing);
    expect(app.menuOpen, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fullscreen panel and dialog close without blocking the next menu',
    (tester) async {
      final app = AppState();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appProvider.overrideWith((ref) => app)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    TextButton(
                      onPressed: () => panel(
                        context,
                        'Settings',
                        const SizedBox(),
                        fullscreen: true,
                      ),
                      child: const Text('Open settings'),
                    ),
                    TextButton(
                      onPressed: () => showClosingDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Confirmation'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Done'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('Open dialog'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(app.menuOpen, isTrue);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);
      expect(app.menuOpen, isFalse);
      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Confirmation'), findsNothing);
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Reduce Motion disables closing blur', (tester) async {
    final animation = AnimationController(vsync: tester, value: 1);
    addTearDown(animation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: ClosingBlur(animation: animation, child: const Text('Search')),
        ),
      ),
    );
    animation.value = 0.3;
    await tester.pump();
    expect(
      tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
      isFalse,
    );
  });
}
