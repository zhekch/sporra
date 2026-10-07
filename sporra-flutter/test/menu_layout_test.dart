import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/sheets.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  testWidgets('Statistics switches to routes with miniature geometry', (
    tester,
  ) async {
    final app = AppState(
      api: SporraApi(
        client: MockClient((request) async {
          if (request.url.path == '/api/stats') {
            return http.Response(
              '{"countries":[],"regions":[],"km2":0,"countryTotal":200,"days":0,"streakDays":0,"years":[]}',
              200,
            );
          }
          return http.Response(
            '{"routes":[{"id":"1","name":"Morning walk","sport":"Walk","firstAt":1,"lengthM":100,"geom":[[[8,47],[8.1,47.1],[8.2,47.05]]]}],"distance":"100 m","years":[]}',
            200,
          );
        }),
      )..server = 'https://example.test',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((ref) => app)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showStats(context, app),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Ground covered'), findsOneWidget);
    await tester.tap(find.text('Routes'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Morning walk'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(TabBarView),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    expect(find.text('Morning walk'), findsOneWidget);
    expect(find.byType(RouteMiniature), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
