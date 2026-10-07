import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:maplibre_gl/maplibre_gl.dart';

mb.Point mapboxPoint(LatLng p) =>
    mb.Point(coordinates: mb.Position(p.longitude, p.latitude));
LatLng mapboxLatLng(mb.Point p) =>
    LatLng(p.coordinates.lat.toDouble(), p.coordinates.lng.toDouble());

// Keep app overlays in the style specification both engines understand. Only
// the adapter knows about Standard's slots and the SDK's camera/image APIs.
class NativeMapController {
  NativeMapController.libre(this.libre) : box = null;
  NativeMapController.box(this.box) : libre = null;
  final MapLibreMapController? libre;
  final mb.MapboxMap? box;
  CameraPosition? boxCamera;
  CameraPosition? get cameraPosition => libre?.cameraPosition ?? boxCamera;

  Future<LatLngBounds> getVisibleRegion() async {
    if (libre != null) return libre!.getVisibleRegion();
    final c = await box!.getCameraState();
    final b = await box!.coordinateBoundsForCameraUnwrapped(
      mb.CameraOptions(
        center: c.center,
        zoom: c.zoom,
        pitch: c.pitch,
        bearing: c.bearing,
        padding: c.padding,
      ),
    );
    return LatLngBounds(
      southwest: mapboxLatLng(b.southwest),
      northeast: mapboxLatLng(b.northeast),
    );
  }

  Future<LatLng> toLatLng(math.Point<double> p) async => libre != null
      ? libre!.toLatLng(p)
      : mapboxLatLng(
          await box!.coordinateForPixel(mb.ScreenCoordinate(x: p.x, y: p.y)),
        );

  Future<LatLng?> requestMyLocationLatLng() async {
    if (libre != null) return libre!.requestMyLocationLatLng();
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        timeLimit: Duration(seconds: 15),
      ),
    );
    return LatLng(p.latitude, p.longitude);
  }

  Future<void> animateCamera(CameraUpdate update, {Duration? duration}) async {
    if (libre != null) {
      await libre!.animateCamera(update, duration: duration);
      return;
    }
    await box!.easeTo(
      await _camera(update),
      mb.MapAnimationOptions(
        duration:
            (duration ?? const Duration(milliseconds: 450)).inMilliseconds,
      ),
    );
  }

  Future<void> moveCamera(CameraUpdate update) async {
    if (libre != null) {
      await libre!.moveCamera(update);
      return;
    }
    await box!.setCamera(await _camera(update));
  }

  Future<mb.CameraOptions> _camera(CameraUpdate update) async {
    final j = update.toJson() as List;
    switch (j[0]) {
      case 'newCameraPosition':
        final p = j[1] as Map;
        return mb.CameraOptions(
          center: mapboxPoint(LatLng(p['target'][0], p['target'][1])),
          zoom: p['zoom'],
          pitch: p['tilt'],
          bearing: p['bearing'],
        );
      case 'newLatLngZoom':
        return mb.CameraOptions(
          center: mapboxPoint(LatLng(j[1][0], j[1][1])),
          zoom: j[2],
        );
      case 'newLatLngBounds':
        final b = j[1] as List;
        return box!.cameraForCoordinateBounds(
          mb.CoordinateBounds(
            southwest: mapboxPoint(LatLng(b[0][0], b[0][1])),
            northeast: mapboxPoint(LatLng(b[1][0], b[1][1])),
            infiniteBounds: false,
          ),
          mb.MbxEdgeInsets(left: j[2], top: j[3], right: j[4], bottom: j[5]),
          0,
          0,
          null,
          null,
        );
      case 'tiltTo':
        return mb.CameraOptions(pitch: j[1]);
      default:
        throw UnsupportedError('Unsupported camera update: ${j[0]}');
    }
  }

  Future<Uint8List> takeSnapshot() =>
      libre != null ? libre!.takeSnapshot() : box!.snapshot();
  Future<List<String>> getLayerIds() async => libre != null
      ? (await libre!.getLayerIds()).map((id) => '$id').toList()
      : (await box!.getStyleLayers())
            .whereType<mb.StyleObjectInfo>()
            .map((l) => l.id)
            .toList();
  Future<List> queryRenderedFeaturesInRect(
    Rect rect,
    List<String> ids,
    dynamic filter,
  ) async {
    if (libre != null) {
      return libre!.queryRenderedFeaturesInRect(rect, ids, filter);
    }
    final hits = await box!.queryRenderedFeatures(
      mb.RenderedQueryGeometry.fromScreenBox(
        mb.ScreenBox(
          min: mb.ScreenCoordinate(x: rect.left, y: rect.top),
          max: mb.ScreenCoordinate(x: rect.right, y: rect.bottom),
        ),
      ),
      mb.RenderedQueryOptions(
        layerIds: ids,
        filter: filter == null ? null : jsonEncode(filter),
      ),
    );
    return hits
        .whereType<mb.QueriedRenderedFeature>()
        .map((h) => Map<String, dynamic>.from(h.queriedFeature.feature))
        .toList();
  }

  Future<List<dynamic>> getClusterLeaves(
    String source,
    Map<String, dynamic> cluster, {
    int limit = 500,
    int offset = 0,
  }) async {
    if (libre != null) {
      return libre!.getClusterLeaves(
        source,
        (cluster['properties']['cluster_id'] as num).toInt(),
        limit: limit,
        offset: offset,
      );
    }
    final result = await box!.getGeoJsonClusterLeaves(
      source,
      Map<String?, Object?>.from(cluster),
      limit,
      offset,
    );
    if (result.featureCollection == null) {
      throw StateError(result.value ?? 'Photo group could not be read.');
    }
    return result.featureCollection!.whereType<Map>().toList();
  }

  Future<void> addSource(String id, SourceProperties props) async {
    if (libre != null) return libre!.addSource(id, props);
    final p = props.toJson();
    await box!.addStyleSource(id, jsonEncode(p));
  }

  Future<void> setGeoJsonSource(String id, Map<String, dynamic> data) =>
      libre != null
      ? libre!.setGeoJsonSource(id, data)
      : box!.setStyleSourceProperty(id, 'data', jsonEncode(data));
  Future<void> addImageSource(
    String id,
    Uint8List bytes,
    LatLngQuad coordinates,
  ) async {
    if (libre != null) return libre!.addImageSource(id, bytes, coordinates);
    await box!.addStyleSource(
      id,
      jsonEncode({
        'type': 'image',
        'coordinates': [
          coordinates.topLeft,
          coordinates.topRight,
          coordinates.bottomRight,
          coordinates.bottomLeft,
        ].map((p) => [p.longitude, p.latitude]).toList(),
      }),
    );
    await box!.updateImageForSource(id, mb.StyleImage.bytes(bytes));
  }

  Future<void> updateImageSource(
    String id,
    Uint8List bytes,
    LatLngQuad coordinates,
  ) async {
    if (libre != null) return libre!.updateImageSource(id, bytes, coordinates);
    await box!.setStyleSourceProperty(
      id,
      'coordinates',
      [
        coordinates.topLeft,
        coordinates.topRight,
        coordinates.bottomRight,
        coordinates.bottomLeft,
      ].map((p) => [p.longitude, p.latitude]).toList(),
    );
    await box!.updateImageForSource(id, mb.StyleImage.bytes(bytes));
  }

  Future<void> setLayerProperties(String id, LayerProperties props) async {
    if (libre != null) return libre!.setLayerProperties(id, props);
    for (final p in props.toJson().entries) {
      if (p.value != null) await box!.setStyleLayerProperty(id, p.key, p.value);
    }
  }

  Future<void> setLayerVisibility(String id, bool visible) => libre != null
      ? libre!.setLayerVisibility(id, visible)
      : box!.setStyleLayerProperty(
          id,
          'visibility',
          visible ? 'visible' : 'none',
        );

  Future<void> _add(
    String source,
    String id,
    String type,
    LayerProperties props, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
  }) async {
    final layer = nativeMapboxLayer(
      source,
      id,
      type,
      props.toJson(),
      sourceLayer: sourceLayer,
      minzoom: minzoom,
      maxzoom: maxzoom,
      filter: filter,
    );
    await box!.addStyleLayer(
      jsonEncode(layer),
      belowLayerId == null ? null : mb.LayerPosition(below: belowLayerId),
    );
  }

  Future<void> removeLayer(String id) =>
      libre != null ? libre!.removeLayer(id) : box!.removeStyleLayer(id);
  Future<void> addImage(String id, Uint8List png, {bool sdf = false}) =>
      libre != null
      ? libre!.addImage(id, png, sdf)
      : box!.addImage(id, 1, mb.StyleImage.bytes(png), sdf: sdf);

  Future<void> addReferenceLayer(
    Map<String, dynamic> layer, {
    String? below,
  }) async {
    final source = layer['source'] as String, id = layer['id'] as String;
    final properties = Map<String, dynamic>.from({
      ...?layer['paint'],
      ...?layer['layout'],
    });
    final type = layer['type'];
    if (libre == null) {
      await box!.addStyleLayer(
        jsonEncode(
          nativeMapboxLayer(
            source,
            id,
            type,
            properties,
            sourceLayer: layer['source-layer'],
            minzoom: (layer['minzoom'] as num?)?.toDouble(),
            maxzoom: (layer['maxzoom'] as num?)?.toDouble(),
            filter: layer['filter'],
          ),
        ),
        below == null ? null : mb.LayerPosition(below: below),
      );
      return;
    }
    for (final entry in properties.entries.toList()) {
      final value = entry.value;
      if (entry.key.endsWith('color') &&
          value is List &&
          value.length == 5 &&
          value.first == 'rgba') {
        final channels = [
          (255 * (value[4] as num)).round(),
          value[1],
          value[2],
          value[3],
        ];
        properties[entry.key] =
            '#${channels.map((n) => (n as num).round().toRadixString(16).padLeft(2, '0')).join()}';
      }
    }
    switch (type) {
      case 'line':
        await libre!.addLineLayer(
          source,
          id,
          LineLayerProperties.fromJson(properties),
          belowLayerId: below,
          sourceLayer: layer['source-layer'],
          minzoom: (layer['minzoom'] as num?)?.toDouble(),
          maxzoom: (layer['maxzoom'] as num?)?.toDouble(),
          filter: layer['filter'],
        );
      case 'symbol':
        await libre!.addSymbolLayer(
          source,
          id,
          SymbolLayerProperties.fromJson(properties),
          belowLayerId: below,
          sourceLayer: layer['source-layer'],
          minzoom: (layer['minzoom'] as num?)?.toDouble(),
          maxzoom: (layer['maxzoom'] as num?)?.toDouble(),
          filter: layer['filter'],
        );
      case 'fill':
        await libre!.addFillLayer(
          source,
          id,
          FillLayerProperties.fromJson(properties),
          belowLayerId: below,
          sourceLayer: layer['source-layer'],
          minzoom: (layer['minzoom'] as num?)?.toDouble(),
          maxzoom: (layer['maxzoom'] as num?)?.toDouble(),
          filter: layer['filter'],
        );
      case 'circle':
        await libre!.addCircleLayer(
          source,
          id,
          CircleLayerProperties.fromJson(properties),
          belowLayerId: below,
          sourceLayer: layer['source-layer'],
          minzoom: (layer['minzoom'] as num?)?.toDouble(),
          maxzoom: (layer['maxzoom'] as num?)?.toDouble(),
          filter: layer['filter'],
        );
      default:
        throw UnsupportedError('Unsupported reference layer: $type');
    }
  }

  Future<void> addLineLayer(
    String source,
    String id,
    LineLayerProperties props, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
  }) => libre != null
      ? libre!.addLineLayer(
          source,
          id,
          props,
          belowLayerId: belowLayerId,
          sourceLayer: sourceLayer,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
        )
      : _add(
          source,
          id,
          'line',
          props,
          belowLayerId: belowLayerId,
          sourceLayer: sourceLayer,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
        );
  Future<void> addSymbolLayer(
    String source,
    String id,
    SymbolLayerProperties props, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
  }) => libre != null
      ? libre!.addSymbolLayer(
          source,
          id,
          props,
          belowLayerId: belowLayerId,
          sourceLayer: sourceLayer,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
        )
      : _add(
          source,
          id,
          'symbol',
          props,
          belowLayerId: belowLayerId,
          sourceLayer: sourceLayer,
          minzoom: minzoom,
          maxzoom: maxzoom,
          filter: filter,
        );
  Future<void> addCircleLayer(
    String source,
    String id,
    CircleLayerProperties props, {
    String? belowLayerId,
    double? minzoom,
    dynamic filter,
  }) => libre != null
      ? libre!.addCircleLayer(
          source,
          id,
          props,
          belowLayerId: belowLayerId,
          minzoom: minzoom,
          filter: filter,
        )
      : _add(
          source,
          id,
          'circle',
          props,
          belowLayerId: belowLayerId,
          minzoom: minzoom,
          filter: filter,
        );
  Future<void> addFillLayer(
    String source,
    String id,
    FillLayerProperties props, {
    String? belowLayerId,
  }) => libre != null
      ? libre!.addFillLayer(source, id, props, belowLayerId: belowLayerId)
      : _add(source, id, 'fill', props, belowLayerId: belowLayerId);
  Future<void> addRasterLayer(
    String source,
    String id,
    RasterLayerProperties props, {
    String? belowLayerId,
  }) => libre != null
      ? libre!.addRasterLayer(source, id, props, belowLayerId: belowLayerId)
      : _add(source, id, 'raster', props, belowLayerId: belowLayerId);
}

Map<String, dynamic> nativeMapboxLayer(
  String source,
  String id,
  String type,
  Map<String, dynamic> properties, {
  String? sourceLayer,
  double? minzoom,
  double? maxzoom,
  dynamic filter,
}) {
  const layoutKeys = {
    'visibility',
    'line-cap',
    'line-join',
    'line-miter-limit',
    'line-round-limit',
  };
  final paint = <String, dynamic>{}, layout = <String, dynamic>{};
  for (final p in properties.entries) {
    if (p.value == null) continue;
    final isLayout =
        layoutKeys.contains(p.key) ||
        (type == 'symbol' &&
            !RegExp(r'^((text|icon)-(opacity|color|halo|translate|emissive))')
                .hasMatch(p.key));
    (isLayout ? layout : paint)[p.key] = p.value;
  }
  final ground = id.startsWith('blob-') || id == 'areas-fill';
  // Match the web slots: ground under roads, routes under labels, pins on top.
  final route =
      id.startsWith('activities-') || id.startsWith('activity-metric-');
  final slot = ground
      ? 'bottom'
      : route
      ? 'middle'
      : 'top';
  if (type == 'line' &&
      (route || id.startsWith('trip-') || id.startsWith('place-selection-'))) {
    layout['line-elevation-reference'] = 'ground';
  }
  if (type == 'raster') paint['raster-emissive-strength'] = 1;
  if (type == 'line') paint['line-emissive-strength'] = 1;
  if (type == 'circle') paint['circle-emissive-strength'] = 1;
  if (type == 'fill') paint['fill-emissive-strength'] = 1;
  if (type == 'symbol') {
    paint['text-emissive-strength'] = 1;
    paint['icon-emissive-strength'] = 1;
  }
  return {
    'id': id,
    'type': type,
    'source': source,
    'slot': slot,
    'source-layer': ?sourceLayer,
    'minzoom': ?minzoom,
    'maxzoom': ?maxzoom,
    'filter': ?filter,
    'paint': paint,
    'layout': layout,
  };
}
