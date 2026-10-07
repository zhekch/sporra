import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:sporra_flutter/src/appearance.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'Sporra',
      packageName: 'com.zhekch.sporra.flutter',
      version: '0.12.0',
      buildNumber: '16',
      buildSignature: '',
    ),
  );
  testWidgets('Settings reads the live server version on each opening', (
    tester,
  ) async {
    var version = '0.134.0', reads = 0;
    final app = AppState(
      api: SporraApi(
        client: MockClient((request) async {
          expect(request.url.path, '/api/health');
          reads++;
          return http.Response('{"app":"sporra","version":"$version"}', 200);
        }),
      )..server = 'https://example.test',
    );
    addTearDown(app.dispose);
    Widget settings() => MaterialApp(
      home: Scaffold(
        body: SettingsTabs(
          app: app,
          childBuilder: (_) => const SizedBox(height: 100),
        ),
      ),
    );
    await tester.pumpWidget(settings());
    await tester.pumpAndSettle();
    expect(find.text('Server version: 0.134.0'), findsOneWidget);
    expect(find.text('iOS version: 0.12.0 (16)'), findsOneWidget);
    expect(find.textContaining('Signed in as'), findsNothing);
    final footer = tester.getTopLeft(find.text('iOS version: 0.12.0 (16)'));
    expect(
      footer.dy,
      greaterThan(tester.getBottomLeft(find.byType(ChoiceChip).first).dy),
    );
    await tester.tap(find.text('Map layers'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('iOS version: 0.12.0 (16)')), footer);
    version = '0.135.0';
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(settings());
    await tester.pumpAndSettle();
    expect(find.text('Server version: 0.135.0'), findsOneWidget);
    expect(reads, 2);
  });
  testWidgets('Settings reports unavailable when version cannot be fetched', (
    tester,
  ) async {
    final app = AppState(
      api: SporraApi(
        client: MockClient((_) async => http.Response('offline', 503)),
      )..server = 'https://example.test',
    );
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsTabs(
            app: app,
            childBuilder: (_) => const SizedBox(height: 100),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Server version: unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
      final impacts = <dynamic>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            impacts.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
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
                      Builder(
                        builder: (menuContext) => ListView(
                          shrinkWrap: true,
                          children: [
                            const ListTile(title: Text('Ride')),
                            ListTile(
                              title: const Text('Walk'),
                              onTap: () => panel(
                                menuContext,
                                'Nested menu',
                                const Text('Submenu content'),
                              ),
                            ),
                          ],
                        ),
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
      final corners = tester
          .widget<ClipRSuperellipse>(
            find.descendant(
              of: find.byType(Glass),
              matching: find.byType(ClipRSuperellipse),
            ),
          )
          .borderRadius;
      expect(corners, BorderRadius.circular(43));
      expect(tester.getSize(find.byType(Glass)).height, lessThan(280));
      expect(tester.getBottomLeft(find.byType(Glass)).dy, 832);
      await tester.tap(find.text('Walk'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ClipRSuperellipse>(
              find.descendant(
                of: find.byType(Glass),
                matching: find.byType(ClipRSuperellipse),
              ),
            )
            .borderRadius,
        corners,
      );
      expect(find.text('Submenu content'), findsOneWidget);
      expect(impacts, isEmpty);
      expect(
        webTheme(menuRadius: menuCornerRadius(context)).dialogTheme.shape,
        RoundedSuperellipseBorder(borderRadius: corners),
      );
      panel(context, 'Settings', const Text('Only the new panel'));
      await tester.pumpAndSettle();
      expect(find.text('Choose an activity'), findsNothing);
      expect(find.text('Only the new panel'), findsOneWidget);
      expect(app.menuOpen, isTrue);
      await tester.tapAt(const Offset(5, 100));
      await tester.pumpAndSettle();
      expect(find.text('Only the new panel'), findsNothing);
      expect(impacts, ['HapticFeedbackType.lightImpact']);
      showSettings(context, app);
      await tester.pumpAndSettle();
      expect(find.byType(ChoiceChip), findsNWidgets(7));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Map layers'));
      await tester.pumpAndSettle();
      expect(find.text('Mapbox public token'), findsOneWidget);
      expect(find.text('Home'), findsNothing);
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('One dialog')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mapbox public token'), findsOneWidget);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(find.text('Mapbox public token'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(app.menuOpen, isFalse);
      expect(impacts, [
        'HapticFeedbackType.lightImpact',
        'HapticFeedbackType.lightImpact',
      ]);
      final removal = confirmRemoval(
        context,
        'Remove trip',
        'Delete this trip?',
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).shape,
        menuShape(context),
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await removal, isFalse);
      final name = askText(context, 'Trip name', 'Old name');
      await tester.pumpAndSettle();
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).shape,
        menuShape(context),
      );
      await tester.enterText(find.byType(CupertinoTextField), 'New name');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      expect(await name, 'New name');
      expect(tester.takeException(), isNull);
    },
  );
}
