import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/appearance.dart';
import 'package:sporra_flutter/src/native.g.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  testWidgets(
    'inactive services stay collapsed and connect shares the status row',
    (tester) async {
      final app = AppState(
        api: SporraApi(
          client: MockClient((_) async => http.Response('{"link":null}', 200)),
        )..server = 'https://example.test',
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: webTheme(),
          home: Scaffold(
            body: ListView(
              children: [
                Builder(builder: (context) => phoneSyncTile(context, app)),
                ConnectorSettings(app: app, kind: 'strava', inline: true),
                ConnectorSettings(app: app, kind: 'ha', inline: true),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Not connected'), findsNothing);
      final actionX = tester.getCenter(find.byTooltip('Sync phone')).dx;
      for (final arrow in find.byType(DisclosureChevron).evaluate()) {
        expect(
          tester.getCenter(find.byWidget(arrow.widget)).dx,
          closeTo(actionX, 0.1),
        );
      }
      await tester.tap(find.text('Strava'));
      await tester.pumpAndSettle();
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.byTooltip('Connect Strava'), findsOneWidget);
      expect(find.text('Connect'), findsNothing);
      expect(
        tester.getCenter(find.text('Not connected')).dy,
        closeTo(tester.getCenter(find.byTooltip('Connect Strava')).dy, 1),
      );
      expect(find.byIcon(CupertinoIcons.link), findsOneWidget);
      expect(
        tester.getCenter(find.byTooltip('Connect Strava')).dx,
        closeTo(actionX, 0.1),
      );
    },
  );
  testWidgets(
    'enabled service starts expanded and disabled service starts collapsed',
    (tester) async {
      final app = AppState(
        api: SporraApi(
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'link': request.url.path == '/api/strava'
                    ? {
                        'connected': true,
                        'enabled': false,
                        'intervalMin': 60,
                        'saveRoutes': true,
                      }
                    : {
                        'enabled': true,
                        'baseUrl': 'https://home.test',
                        'intervalMin': 15,
                        'maxAccuracy': 100,
                        'entities': [],
                      },
              }),
              200,
            ),
          ),
        )..server = 'https://example.test',
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: webTheme(),
          home: Scaffold(
            body: ListView(
              children: [
                ConnectorSettings(app: app, kind: 'strava', inline: true),
                ConnectorSettings(app: app, kind: 'ha', inline: true),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Sync Strava'), findsNothing);
      expect(find.byTooltip('Sync Home Assistant'), findsOneWidget);
      expect(find.text('Sync automatically'), findsOneWidget);
      await tester.tap(find.text('Strava'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Sync Strava'), findsOneWidget);
    },
  );
  testWidgets('phone has one editable name and an icon sync action', (
    tester,
  ) async {
    final app = AppState()..device = {'deviceName': 'iPhone'};
    addTearDown(app.dispose);
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.sporra_flutter.SporraNative.configure',
      SporraNative.pigeonChannelCodec,
    );
    Map<String, dynamic>? patch;
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
      channel,
      (message) async {
        patch = jsonDecode(
          (message as List).first as String,
        ) as Map<String, dynamic>;
        return [
          jsonEncode({'deviceName': patch!['deviceName']}),
        ];
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: webTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => AnimatedBuilder(
              animation: app,
              builder: (_, _) => phoneSyncTile(context, app),
            ),
          ),
        ),
      ),
    );
    expect(find.text('iPhone'), findsOneWidget);
    expect(find.text('Your phone'), findsNothing);
    expect(find.text('Sync now'), findsNothing);
    expect(find.byTooltip('Sync phone'), findsOneWidget);
    await tester.tap(find.text('iPhone'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField), 'My iPhone');
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byTooltip('Save phone name'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(patch, {'deviceName': 'My iPhone'});
    expect(find.text('My iPhone'), findsOneWidget);
  });
}
