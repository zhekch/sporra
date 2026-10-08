import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:sporra_flutter/src/api.dart';
import 'package:sporra_flutter/src/map_interaction.dart';
import 'package:sporra_flutter/src/map_preferences.dart';
import 'package:sporra_flutter/src/state.dart';

void main() {
  test('location focus stays filled near the fix and clears after a pan', () {
    const point = LatLng(47, 8);
    expect(
      cameraAtLocation(const CameraPosition(target: point, zoom: 13.6), point),
      isTrue,
    );
    expect(
      cameraAtLocation(
        const CameraPosition(target: LatLng(47.0001, 8), zoom: 13.6),
        point,
      ),
      isTrue,
    );
    expect(
      cameraAtLocation(
        const CameraPosition(target: LatLng(47.001, 8), zoom: 13.6),
        point,
      ),
      isFalse,
    );
    expect(
      cameraAtLocation(const CameraPosition(target: point, zoom: 7), null),
      isFalse,
    );
    expect(
      cameraAtLocation(
        const CameraPosition(target: LatLng(0, 180), zoom: 13.6),
        const LatLng(0, -180),
      ),
      isTrue,
    );
  });

  test('location focus uses tiniest cell zoom and keeps perspective', () {
    final camera = locationCamera(
      const LatLng(47, 8),
      const CameraPosition(
        target: LatLng(0, 0),
        zoom: 7,
        tilt: 65,
        bearing: 123,
      ),
    );
    expect(camera.target, const LatLng(47, 8));
    expect(camera.zoom, 13.6);
    expect(camera.tilt, 65);
    expect(camera.bearing, 123);
  });

  test(
    'view preferences survive restart and stay scoped to the account',
    () async {
      final directory = await Directory.systemTemp.createTemp('sporra-view-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/view.json');
      final preferences = MapPreferences();
      await preferences.restore(file, 'server/alice');
      preferences.style = 'mapbox';
      preferences.tilt = 55;
      preferences.bearing = 123;
      preferences.save();
      await preferences.flush();
      final restored = MapPreferences();
      await restored.restore(file, 'server/alice');
      expect(restored.style, 'mapbox');
      expect(restored.tilt, 55);
      expect(restored.bearing, 123);
      final other = MapPreferences();
      await other.restore(file, 'server/bob');
      expect(other.style, 'dark');
      expect(other.tilt, 0);
      expect(other.bearing, 0);
    },
  );

  test('saved 3D basemap is applied after the account token loads', () async {
    final directory = await Directory.systemTemp.createTemp('sporra-style-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/view.json');
    await file.writeAsString(
      jsonEncode({
        'scope': 'alice',
        'style': 'mapbox',
        'tilt': 55,
        'bearing': 123,
      }),
    );
    final api = SporraApi(
      client: MockClient(
        (_) async =>
            http.Response('{"prefs":{"mapboxToken":"pk.public"}}', 200),
      ),
    )..server = 'https://example.test';
    final app = AppState(api: api);
    await app.mapPreferences.restore(file, 'alice');
    await app.loadPrefs();
    expect(app.style, 'mapbox');
    expect(app.isMapbox, true);
    await app.mapPreferences.flush();
    app.dispose();
  });

  test('damaged preferences and unsupported styles fall back safely', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sporra-invalid-view-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/view.json');
    await file.writeAsString('{bad');
    final preferences = MapPreferences();
    await preferences.restore(file, 'alice');
    expect(preferences.style, 'dark');
    await file.writeAsString(
      jsonEncode({
        'scope': 'bob',
        'style': 'unknown',
        'tilt': 100,
        'bearing': -5,
      }),
    );
    final unsupported = MapPreferences();
    await unsupported.restore(file, 'bob');
    expect(unsupported.style, 'dark');
    expect(unsupported.tilt, 85);
    expect(unsupported.bearing, 355);
  });
}
