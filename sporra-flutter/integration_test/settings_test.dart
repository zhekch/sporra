import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/appearance.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Import buttons align and links action follows input', (
    tester,
  ) async {
    final app = AppState(
      api: SporraApi(
        client: MockClient(
          (_) async => http.Response(
            '{"app":"sporra","version":"0.141.0","link":null}',
            200,
          ),
        ),
      )..server = 'https://example.test',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((ref) => app)],
        child: MaterialApp(
          theme: webTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showSettings(context, app),
                  child: const Text('Settings'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Import'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Import'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Import files'), findsOneWidget);
    expect(find.text('Import links'), findsNothing);
    await binding.takeScreenshot('import-empty');
    await tester.enterText(
      find.byType(TextField),
      'https://www.komoot.com/tour/123456',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Import links'), findsOneWidget);
    await binding.takeScreenshot('import-links');
    expect(tester.takeException(), isNull);
  });
}
