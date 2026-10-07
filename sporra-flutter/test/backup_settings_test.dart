import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/state.dart';
import 'package:sporra_flutter/src/backup_settings.dart';
import 'package:sporra_flutter/src/appearance.dart';

void main() {
  test('backup presets preserve existing schedules', () {
    for (final cron in [
      '15 * * * *',
      '10 */6 * * *',
      '30 4 * * *',
      '45 6 * * 2',
      '0 23 31 * *',
      '0 2 * 1 3',
      'invalid',
    ]) {
      expect(BackupSchedule.parse(cron).cron, cron);
    }
    expect(BackupSchedule.parse('0 4 * * 7').weekday, 0);
    expect(BackupSchedule.parse('0 24 * * *').preset, 'custom');
    expect(BackupSchedule.parse('0 4 32 * *').preset, 'custom');
  });
  testWidgets(
    'backup settings save schedule and report unchanged server runs',
    (tester) async {
      final status = <String, dynamic>{
        'enabled': true,
        'cron': '30 4 * * *',
        'keep': 14,
        'lastOk': 1234567890,
        'lastRun': 1234567900,
        'nextRun': 1234568000,
        'lastSize': 2048,
        'runs': 2,
        'skips': 3,
        'dir': '/backups',
        'files': [
          {'name': 'backup.db'},
        ],
      };
      Map<String, dynamic>? saved;
      final app = AppState(
        api: SporraApi(
          client: MockClient((request) async {
            if (request.method == 'POST' && request.url.path == '/api/backup') {
              saved = Map<String, dynamic>.from(jsonDecode(request.body));
              status.addAll(saved!);
            }
            return http.Response(
              jsonEncode({
                'backup': status,
                if (request.url.path.endsWith('/run')) ...{
                  'status': 'unchanged',
                  'reason': 'no changes',
                },
              }),
              200,
            );
          }),
        )..server = 'https://example.test',
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: webTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: BackupSettings(
                app: app,
                fileBuilder: (_, f) => Text(f['name']),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Last backup'), findsOneWidget);
      expect(find.text('Next backup'), findsOneWidget);
      expect(find.text('backup.db'), findsOneWidget);
      await tester.tap(find.text('Every day'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Every week'));
      await tester.pumpAndSettle();
      expect(find.text('Monday'), findsOneWidget);
      await tester.ensureVisible(find.text('Save schedule'));
      await tester.tap(find.text('Save schedule'));
      await tester.pumpAndSettle();
      expect(saved, {'enabled': true, 'cron': '30 4 * * 1', 'keep': 14});
      expect(find.text('Schedule saved.'), findsOneWidget);
      await tester.ensureVisible(find.text('Back up now on the server'));
      await tester.tap(find.text('Back up now on the server'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing to back up — no changes.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
