import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/closing_blur.dart';

void main() {
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
                  animation: animation,
                  child: const SizedBox(
                    width: 60,
                    height: 60,
                    child: ColoredBox(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
    expect(alpha(30), lessThan(240));
    expect(alpha(60), greaterThan(240));
  });

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
