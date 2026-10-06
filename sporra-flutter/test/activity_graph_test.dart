import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/activity_graph.dart';
import 'package:sporra_flutter/src/appearance.dart';
import 'package:sporra_flutter/src/state.dart';
import 'package:sporra_flutter/src/map_screen.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

final graph = <String, dynamic>{
  'metric': 'speed',
  'min': 1,
  'max': 3,
  'maxX': 100,
  'minLabel': '3.6 km/h',
  'maxLabel': '10.8 km/h',
  'ticks': <dynamic>[],
  'runs': [
    [
      {'i': 0, 'x': 0, 'y': 1, 'color': null, 'label': '3.6 km/h'},
      {
        'i': 1,
        'x': 25,
        'y': 2,
        'color': 'rgb(232,184,42)',
        'label': '7.2 km/h',
      },
    ],
    [
      {'i': 2, 'x': 75, 'y': 2, 'color': null, 'label': '7.2 km/h'},
      {
        'i': 3,
        'x': 100,
        'y': 3,
        'color': 'rgb(36,158,74)',
        'label': '10.8 km/h',
      },
    ],
  ],
};
void main() {
  test('native layer patches retain omitted style properties', () {
    expect(
      const LayerPatch(FillLayerProperties(fillOpacity: .3))
          .toJson(skipNulls: false),
      {'fill-opacity': .3},
    );
    expect(
      const LayerPatch(LineLayerProperties(visibility: 'none'))
          .toJson(skipNulls: false),
      {'visibility': 'none'},
    );
  });
  testWidgets('scrubbing selects the nearest recorded sample across a gap', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: webTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ActivityGraph(graph: graph, onScrub: (i) => selected = i),
          ),
        ),
      ),
    );
    final paint = find.descendant(
      of: find.byType(ActivityGraph),
      matching: find.byWidgetPredicate((w) => w is SizedBox && w.height == 72),
    );
    final rect = tester.getRect(paint);
    await tester.tapAt(Offset(rect.left + rect.width * 0.8, rect.center.dy));
    expect(selected, 2);
    expect(find.text('10.8 km/h'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('missing trace gives an explicit empty state', (tester) async {
    final app = AppState()
      ..activity = {
        'route': {
          'id': 1,
          'name': 'Undated walk',
          'sport': 'Walking',
          'firstAt': 0,
        },
        'summary': {'distance': '1 km'},
        'graphs': {'speed': null, 'elev': null},
      };
    await tester.pumpWidget(
      MaterialApp(
        theme: webTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 430,
            child: ActivityCard(app: app, onZoom: () {}),
          ),
        ),
      ),
    );
    expect(find.byType(ActivityGraph), findsNothing);
    expect(
      find.text('This activity has no recorded speed or elevation data.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    app.dispose();
  });
}
