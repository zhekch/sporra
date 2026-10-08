import 'package:flutter/material.dart';
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
