import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/backup_settings.dart';
import 'package:sporra_flutter/src/loading.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  testWidgets('backup loader stays square in a full-width settings list', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final app = AppState(
      api: SporraApi(client: MockClient((_) => response.future))
        ..server = 'https://example.test',
    );
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              BackupSettings(app: app, fileBuilder: (_, _) => const SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final ring = find.descendant(
      of: find.byType(LoadingIndicator),
      matching: find.byType(CustomPaint),
    );
    expect(tester.getSize(ring), const Size(24, 24));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    response.complete(http.Response('{"backup":{}}', 200));
    await tester.pump();
  });

  testWidgets('closing a visible activity plays the menu close haptic once', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final app = AppState()
      ..activity = {
        'route': {'id': 1},
      };
    addTearDown(app.dispose);
    app.closeActivity();
    await tester.pump();
    app.closeActivity();
    await tester.pump();
    expect(
      calls
          .where((call) => call.method == 'HapticFeedback.vibrate')
          .map((call) => call.arguments),
      ['HapticFeedbackType.lightImpact'],
    );
    expect(app.activity, isNull);
  });

  test(
    'news uses server text, preserves cached map data and persists its toggle',
    () async {
      var routesReads = 0;
      var newsReads = 0;
      var stored = <String, dynamic>{};
      final newsBodies = <Map>[];
      final app = AppState(
        api: SporraApi(
          client: MockClient((request) async {
            if (request.url.path == '/api/whats-new') {
              newsReads++;
              newsBodies.add(jsonDecode(request.body));
              return http.Response(
                jsonEncode(
                  newsReads == 1
                      ? {
                          'show': true,
                          'title': 'New activity: Lunch walk',
                          'detail': 'First visit to Bern.',
                          'activityIds': [7],
                        }
                      : {'show': false},
                ),
                200,
              );
            }
            if (request.url.path == '/api/prefs') {
              if (request.method == 'POST') {
                stored = Map<String, dynamic>.from(
                  jsonDecode(request.body)['prefs'],
                );
              }
              return http.Response(jsonEncode({'prefs': stored}), 200);
            }
            routesReads++;
            return http.Response('{"routes":[]}', 200);
          }),
        )..server = 'https://example.test',
      )..user = {'id': 1};
      addTearDown(app.dispose);
      await app.api.get('/api/routes?fold=1');
      await app.checkAnnouncements();
      expect(app.announcement!['detail'], 'First visit to Bern.');
      expect(app.announcement!['activityIds'], [7]);
      expect(app.announcementRevision, 1);
      await app.api.get('/api/routes?fold=1');
      expect(routesReads, 1);
      await app.setAnnouncementsEnabled(false);
      expect(stored['whatsNew'], 'never');
      expect(app.announcementsEnabled, false);
      expect(app.announcement, isNull);
      expect(newsBodies.last['quiet'], true);
      await app.setAnnouncementsEnabled(true);
      expect(stored['whatsNew'], 'substantial');
      expect(app.announcementsEnabled, true);
      app.user = null;
      final before = newsReads;
      await app.checkAnnouncements();
      expect(newsReads, before);
    },
  );
}
