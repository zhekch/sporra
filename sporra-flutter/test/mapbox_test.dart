import 'dart:convert';

import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/mapbox.dart';
import 'package:sporra_flutter/src/native_map.dart';

void main() {
  test('only public tokens activate the Mapbox basemaps', () {
    for (final token in ['', 'sk.secret', 'invalid']) {
      expect(usesMapbox('mapbox', token), false);
      expect(usesMapbox('satellite', token), false);
      expect(effectiveBasemap('mapbox', token), 'dark');
      expect(effectiveBasemap('satellite', token), 'satellite');
    }
    expect(usesMapbox('mapbox', ' pk.public '), true);
    expect(usesMapbox('satellite', 'pk.public'), true);
    expect(usesMapbox('dark', 'pk.public'), false);
  });
  test(
    'validate Standard access before saving, preserving Mapbox failures',
    () async {
      var requests = 0;
      final good = MockClient((request) async {
        requests++;
        expect(request.url.host, 'api.mapbox.com');
        expect(request.url.path, '/styles/v1/mapbox/standard');
        expect(request.url.queryParameters['access_token'], 'pk.public');
        return http.Response('{}', 200);
      });
      await expectLater(
        checkMapboxToken('sk.secret', client: good),
        throwsFormatException,
      );
      expect(requests, 0);
      await checkMapboxToken(' pk.public ', client: good);
      expect(requests, 1);
      for (final status in [401, 403, 500]) {
        await expectLater(
          checkMapboxToken(
            'pk.public',
            client: MockClient((_) async => http.Response('', status)),
          ),
          throwsFormatException,
        );
      }
    },
  );
  test('Auto follows the web solar phases, including polar seasons', () {
    for (final entry in {
      '03:45': 'dawn',
      '10:00': 'day',
      '19:30': 'dusk',
      '23:00': 'night',
    }.entries) {
      expect(
        sunPhase(
          DateTime.parse('2026-06-21T${entry.key}:00Z'),
          latitude: 46.95,
          longitude: 7.45,
        ),
        entry.value,
      );
    }
    expect(
      sunPhase(
        DateTime.parse('2026-06-21T23:00:00Z'),
        latitude: 69.65,
        longitude: 18.96,
      ),
      isNot('night'),
    );
    expect(
      sunPhase(
        DateTime.parse('2026-12-21T12:00:00Z'),
        latitude: 69.65,
        longitude: 18.96,
      ),
      isNot('day'),
    );
  });
  test(
    'clearing the token preserves preferences and restores free maps',
    () async {
      for (final style in ['mapbox', 'satellite']) {
        Map? saved;
        final api = SporraApi(
          client: MockClient((request) async {
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'prefs': {'mapboxToken': 'pk.old', 'clock': '24'},
                }),
                200,
              );
            }
            saved = jsonDecode(request.body)['prefs'];
            return http.Response('{"ok":true}', 200);
          }),
        )..server = 'https://example.test';
        final app = AppState(api: api)..prefs = {'mapboxToken': 'pk.old'};
        app.setStyle(style);
        await app.setMapboxToken('');
        expect(saved!['clock'], '24');
        expect(saved!['mapboxToken'], '');
        expect(app.isMapbox, false);
        expect(app.style, style == 'mapbox' ? 'dark' : 'satellite');
        app.dispose();
      }
    },
  );
  test('secret tokens never reach account storage', () async {
    var writes = 0;
    final app = AppState(
      api: SporraApi(
        client: MockClient((_) async {
          writes++;
          return http.Response('{}', 200);
        }),
      )..server = 'https://example.test',
    )..prefs = {'mapboxToken': 'pk.old'};
    await expectLater(app.setMapboxToken('sk.secret'), throwsFormatException);
    expect(app.mapboxToken, 'pk.old');
    expect(writes, 0);
    app.dispose();
  });
  test('Standard layers separate layout, paint and slot placement', () {
    final line = nativeMapboxLayer(
      'routes',
      'activities-line',
      'line',
      {
        'line-cap': 'round',
        'line-width': 4,
        'line-color': '#ffffff',
        'visibility': 'visible',
      },
      minzoom: 3,
      filter: ['==', 'sport', 'walk'],
    );
    expect(line['layout'], {
      'line-cap': 'round',
      'visibility': 'visible',
      'line-elevation-reference': 'ground',
    });
    expect(line['paint']['line-width'], 4);
    expect(line['paint']['line-emissive-strength'], 1);
    expect(line['slot'], 'middle');
    expect(line['minzoom'], 3);
    expect(line['filter'], ['==', 'sport', 'walk']);
    expect(nativeMapboxLayer('blob', 'blob-0', 'raster', {})['slot'], 'bottom');
    expect(
      nativeMapboxLayer('areas', 'areas-fill', 'fill', {})['slot'],
      'bottom',
    );
    final label = nativeMapboxLayer('airports', 'airport-label', 'symbol', {
      'text-field': ['get', 'name'],
      'text-color': '#ffffff',
      'text-size': 12,
    });
    expect(label['layout']['text-field'], ['get', 'name']);
    expect(label['layout']['text-size'], 12);
    expect(label['paint']['text-color'], '#ffffff');
  });
}
