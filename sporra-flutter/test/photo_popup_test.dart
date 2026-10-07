import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/appearance.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:sporra_flutter/src/state.dart';

class _Photos extends AppState {
  @override
  Future<Uint8List> thumbnail(int index, int pixels) =>
      Future.error('No thumbnail');
}

void main() {
  testWidgets('photo popup fits small groups and caps larger galleries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = _Photos();
    app.photoItems = List.generate(30, (i) => {'index': i, 'video': i == 1});
    var selection = <int>{0};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((ref) => app)],
        child: MaterialApp(
          theme: webTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPhotos(context, app, indices: selection),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('1 photo'), findsOneWidget);
    expect(find.byType(Divider), findsNothing);
    final singleHeight = tester.getSize(find.byType(Glass)).height;
    expect(singleHeight, lessThan(500));
    final singleGrid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (singleGrid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      1,
    );
    await tester.tap(find.byIcon(CupertinoIcons.xmark));
    await tester.pumpAndSettle();
    selection = Set<int>.from(List.generate(30, (i) => i));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('29 photos · 1 video'), findsOneWidget);
    final largeHeight = tester.getSize(find.byType(Glass)).height;
    expect(largeHeight, greaterThan(singleHeight));
    expect(largeHeight, lessThanOrEqualTo(620));
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(GridView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
