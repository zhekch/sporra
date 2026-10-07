import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'mapbox.dart';
import 'native_map.dart';

class MapboxView extends StatefulWidget {
  const MapboxView({
    super.key,
    required this.token,
    required this.satellite,
    required this.light,
    required this.camera,
    required this.onCreated,
    required this.onLoaded,
    required this.onCamera,
    required this.onIdle,
    required this.onTap,
    required this.onError,
  });
  final String token, light;
  final bool satellite;
  final CameraPosition camera;
  final void Function(NativeMapController) onCreated;
  final VoidCallback onLoaded, onIdle;
  final void Function(CameraPosition) onCamera;
  final void Function(LatLng, math.Point<double>) onTap;
  final void Function(String) onError;
  @override
  State<MapboxView> createState() => _MapboxViewState();
}

class _MapboxViewState extends State<MapboxView> {
  NativeMapController? controller;
  bool ready = false;
  bool? landmarks;
  int epoch = 0;
  String get uri => widget.satellite ? standardSatelliteStyle : standardStyle;
  @override
  void initState() {
    super.initState();
    mb.MapboxOptions.setAccessToken(widget.token);
  }

  @override
  void didUpdateWidget(MapboxView old) {
    super.didUpdateWidget(old);
    if (old.satellite != widget.satellite || old.token != widget.token) {
      ready = false;
      epoch++;
      landmarks = null;
      mb.MapboxOptions.setAccessToken(widget.token);
      if (controller == null) return;
      unawaited(
        controller!.box!
            .loadStyleURI(uri)
            .catchError(
              (Object e) => widget.onError('Mapbox style unavailable: $e'),
            ),
      );
    } else if (old.light != widget.light && ready) {
      unawaited(
        configure().catchError(
          (Object e) => widget.onError('Mapbox lighting unavailable: $e'),
        ),
      );
    }
  }

  Future<void> configure() async {
    await controller!.box!.setStyleImportConfigProperties('basemap', {
      'lightPreset': widget.light,
      'backgroundPointOfInterestLabels': 'none',
      'showTransitLabels': false,
      if (widget.satellite) ...{
        'showRoadsAndTransit': true,
        'showPedestrianRoads': false,
      } else ...{
        'show3dLandmarks':
            (controller!.cameraPosition?.zoom ?? widget.camera.zoom) >= 15,
        'show3dFacades': true,
        'showLandmarkIcons': false,
      },
    });
    landmarks = (controller!.cameraPosition?.zoom ?? widget.camera.zoom) >= 15;
  }

  Future<void> styleLoaded() async {
    final ticket = epoch;
    try {
      await configure();
      final map = controller!.box!;
      await map.addStyleSource(
        'sporra-dem',
        jsonEncode({
          'type': 'raster-dem',
          'url': 'mapbox://mapbox.mapbox-terrain-dem-v1',
          'tileSize': 512,
          'maxzoom': 14,
        }),
      );
      await map.setStyleTerrain(
        jsonEncode({'source': 'sporra-dem', 'exaggeration': 1}),
      );
      if (!mounted || ticket != epoch) return;
      ready = true;
      widget.onLoaded();
    } catch (e) {
      if (mounted && ticket == epoch) widget.onError('Mapbox setup failed: $e');
    }
  }

  Future<void> cameraChanged() async {
    final c = controller;
    if (c == null) return;
    final ticket = epoch;
    final p = await c.box!.getCameraState();
    if (!mounted || ticket != epoch) return;
    c.boxCamera = CameraPosition(
      target: mapboxLatLng(p.center),
      zoom: p.zoom,
      tilt: p.pitch,
      bearing: p.bearing,
    );
    widget.onCamera(c.boxCamera!);
    if (ready && !widget.satellite && landmarks != (p.zoom >= 15)) {
      landmarks = p.zoom >= 15;
      await c.box!.setStyleImportConfigProperty(
        'basemap',
        'show3dLandmarks',
        landmarks!,
      );
    }
  }

  @override
  void dispose() {
    epoch++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => mb.MapWidget(
    styleUri: uri,
    viewport: mb.CameraViewportState(
      center: mapboxPoint(widget.camera.target),
      zoom: widget.camera.zoom,
      pitch: widget.camera.tilt,
      bearing: widget.camera.bearing,
    ),
    onMapCreated: (map) async {
      controller = NativeMapController.box(map)..boxCamera = widget.camera;
      widget.onCreated(controller!);
      await map.setBounds(mb.CameraBoundsOptions(maxPitch: 85));
      await map.compass.updateSettings(mb.CompassSettings(enabled: false));
      await map.scaleBar.updateSettings(mb.ScaleBarSettings(enabled: true));
      await map.location.updateSettings(
        mb.LocationComponentSettings(
          enabled: true,
          puckBearingEnabled: true,
          showAccuracyRing: true,
        ),
      );
      map.addInteraction(
        mb.TapInteraction.onMap(
          (p) => widget.onTap(
            mapboxLatLng(p.point),
            math.Point(p.touchPosition.x, p.touchPosition.y),
          ),
        ),
      );
    },
    onStyleLoadedListener: (_) => unawaited(styleLoaded()),
    onCameraChangeListener: (_) => unawaited(cameraChanged()),
    onMapIdleListener: (_) => widget.onIdle(),
    onMapLoadErrorListener: (e) =>
        widget.onError('Mapbox could not load: ${e.message}'),
  );
}
