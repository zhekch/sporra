import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/toast.dart';

void main() {
  testWidgets('top toast replaces old messages and can be swiped away', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    showToast(context, 'First');
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getTopLeft(find.text('First')).dy, lessThan(100));
    showToast(context, 'Second');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('First'), findsNothing);
    await tester.drag(find.byType(Dismissible), const Offset(700, 0));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
    await tester.drag(find.byType(Dismissible), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsNothing);
    dismissToast();
  });
  testWidgets('undo action runs once and removes its toast', (tester) async {
    late BuildContext context;
    var undos = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    showToast(
      context,
      'Activity deleted',
      action: 'Undo',
      onAction: () => undos++,
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(undos, 1);
    expect(find.text('Activity deleted'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    expect(undos, 1);
    dismissToast();
  });
  testWidgets(
    'brief failures stay quiet but sustained failures become visible',
    (tester) async {
      Future<void> notice(String? message) => tester.pumpWidget(
        MaterialApp(
          home: DelayedErrorNotice(
            message: message,
            builder: (value) => Text(value),
          ),
        ),
      );
      await notice('Connection lost');
      await tester.pump(const Duration(milliseconds: 200));
      await notice(null);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Connection lost'), findsNothing);
      await notice('First failure');
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('First failure'), findsNothing);
      await notice('Persistent failure');
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Persistent failure'), findsOneWidget);
      await notice(null);
      expect(find.text('Persistent failure'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
