import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  testWidgets(
    'small panels fit content, hide map controls and follow phone corners',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      late BuildContext context;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (c) {
                context = c;
                return Scaffold(
                  body: TextButton(
                    onPressed: () => panel(
                      c,
                      'Choose an activity',
                      ListView(
                        shrinkWrap: true,
                        children: const [
                          ListTile(title: Text('Ride')),
                          ListTile(title: Text('Walk')),
                        ],
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final app = ProviderScope.containerOf(context).read(appProvider);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(app.menuOpen, isTrue);
      final glass = tester.widget<Glass>(find.byType(Glass));
      expect(glass.radius, 43);
      expect(tester.getSize(find.byType(Glass)).height, lessThan(280));
      expect(tester.getBottomLeft(find.byType(Glass)).dy, 832);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(app.menuOpen, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
