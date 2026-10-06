import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/calendar.dart';

void main() {
  testWidgets('recorded calendar shows trip spans and returns local dates', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    DateTime? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VisitCalendar(
            selected: '2026-08-11',
            days: const {
              '2026-08-11': {'cells': 3, 'routes': 1},
            },
            trips: [
              {
                'name': 'Journey',
                'start': DateTime(2026, 8, 10).millisecondsSinceEpoch ~/ 1000,
                'end': DateTime(2026, 8, 12, 23).millisecondsSinceEpoch ~/ 1000,
              },
            ],
            onPick: (date) => picked = date,
          ),
        ),
      ),
    );
    expect(find.text('August 2026'), findsOneWidget);
    expect(
      find.bySemanticsLabel('2026-08-11 · Journey · 1 activities'),
      findsOneWidget,
    );
    await tester.tap(find.text('11'));
    expect(picked, DateTime(2026, 8, 11));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
