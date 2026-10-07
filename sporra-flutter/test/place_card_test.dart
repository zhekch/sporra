import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/appearance.dart';
import 'package:sporra_flutter/src/place_card.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    Map<String, dynamic> info, {
    VoidCallback? close,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: webTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: PlaceCard(info: info, onClose: close ?? () {}),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'unvisited pill gives the name room and centers close vertically',
    (tester) async {
      var closed = false;
      await mount(tester, {
        'name': 'Bern',
        'visited': false,
      }, close: () => closed = true);
      expect(find.text('Not visited yet'), findsOneWidget);
      final card = tester.getRect(find.byType(PlaceCard));
      expect(card.height, lessThanOrEqualTo(80));
      expect(
        tester.getTopLeft(find.text('Bern')).dx - card.left,
        greaterThanOrEqualTo(24),
      );
      expect(
        tester.getCenter(find.byTooltip('Close place')).dy,
        closeTo(card.center.dy, 0.1),
      );
      final name = tester.widget<Text>(find.text('Bern'));
      final status = tester.widget<Text>(find.text('Not visited yet'));
      expect(name.style!.fontSize, greaterThan(status.style!.fontSize!));
      expect(status.style!.color, Colors.white60);
      await tester.tap(find.byTooltip('Close place'));
      expect(closed, isTrue);
    },
  );

  testWidgets('visit count expands and collapses every server date', (
    tester,
  ) async {
    await mount(tester, {
      'name': 'Bern',
      'visited': true,
      'hits': 100,
      'visitCount': 3,
      'visitDates': ['2024-04-05', '2024-02-03', '2024-01-01'],
    });
    final height = tester.getSize(find.byType(PlaceCard)).height;
    expect(find.text('3 visits'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.chevron_right), findsOneWidget);
    expect(find.text('03.02.2024'), findsNothing);
    await tester.tap(find.text('3 visits'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(PlaceCard)).height, greaterThan(height));
    for (final value in ['05.04.2024', '03.02.2024', '01.01.2024']) {
      expect(find.text(value), findsOneWidget);
    }
    await tester.tap(find.text('3 visits'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(PlaceCard)).height, height);
  });

  testWidgets('undated visited places have no provenance or date disclosure', (
    tester,
  ) async {
    await mount(tester, {
      'name': 'Bern',
      'visited': true,
      'hits': 0,
      'visitDates': [],
    });
    expect(find.text('You have been here'), findsOneWidget);
    expect(find.text('Marked by hand'), findsNothing);
    expect(find.byIcon(CupertinoIcons.chevron_right), findsNothing);
  });
}
