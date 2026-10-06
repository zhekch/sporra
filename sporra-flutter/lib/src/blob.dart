import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

const world = 40075016.68557849;
double mercX(double lng) => lng / 360 * world;
double mercY(double lat) =>
    math.log(
      math.tan(math.pi / 4 + lat.clamp(-85.051129, 85.051129) * math.pi / 360),
    ) *
    world /
    (2 * math.pi);
double longitude(double x) => x / world * 360;
double latitude(double y) =>
    (2 * math.atan(math.exp(y * 2 * math.pi / world)) - math.pi / 2) *
    180 /
    math.pi;
int levelForZoom(double zoom) => zoom < 2.75
    ? 8
    : math.min(
        7,
        math.max(0, ((13.6 - zoom) / (math.log(3) / math.ln2) - 1e-9).ceil()),
      );
List<int> alphaCurve(double edge) {
  final lo = math.max(0.05, 0.4 - edge) * 255;
  final hi = math.min(255.0, math.max(lo + 1, (0.4 + edge) * 255));
  return List.generate(256, (a) {
    final t = ((a - lo) / (hi - lo)).clamp(0.0, 1.0);
    return a == 0 ? 0 : (255 * t * t * (3 - 2 * t)).round();
  });
}

Color parseColor(String value) {
  if (value.startsWith('rgb(')) {
    final n = RegExp(r'\d+')
        .allMatches(value)
        .map((m) => int.parse(m[0]!))
        .toList();
    return Color.fromARGB(255, n[0], n[1], n[2]);
  }
  final hex = value.replaceFirst('#', '');
  return Color(int.parse('ff${hex.substring(0, 6)}', radix: 16));
}

class BlobSheet {
  BlobSheet(this.bytes, this.coordinates);
  final Uint8List bytes;
  final LatLngQuad coordinates;
}

class BlobPainter {
  ui.FragmentProgram? program;
  Future<BlobSheet> paint(
    Map<String, dynamic> data,
    List<double> bounds,
    int width,
    int height,
    bool heat,
  ) async {
    program ??= await ui.FragmentProgram.fromAsset('shaders/blob.frag');
    final west = mercX(bounds[0]);
    var east = mercX(bounds[2]);
    if (east <= west) east += world;
    final south = mercY(bounds[1]), north = mercY(bounds[3]);
    final scale = width / (east - west);
    final unit = math.max((data['radius'] as num).toDouble() * scale, 0.85);
    var recorder = ui.PictureRecorder();
    var canvas = Canvas(recorder);
    final colors = <String, Color>{};
    final discPaint = Paint();
    for (final row in data['rows'] as List) {
      var x = (row[1] as num).toDouble();
      // Choose the nearest world copy even around the date line.
      x =
          (row[1] as num).toDouble() +
          (((west + east) / 2 - (row[1] as num).toDouble()) / world).round() *
              world;
      final y = (row[2] as num).toDouble();
      canvas.drawCircle(
        Offset((x - west) * scale, (north - y) / (north - south) * height),
        row[4] == true ? math.max(unit * 0.9, 2.0) : unit * 0.9,
        discPaint
          ..color = colors.putIfAbsent(
            row[3] as String,
            () => parseColor(row[3]),
          ),
      );
    }
    var picture = recorder.endRecording();
    var image = await picture.toImage(width, height);
    picture.dispose();
    Future<ui.Image> blur(ui.Image source, double sigma) async {
      final r = ui.PictureRecorder();
      final c = Canvas(r);
      c.saveLayer(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      );
      c.drawImage(source, Offset.zero, Paint());
      c.restore();
      final p = r.endRecording();
      final i = await p.toImage(width, height);
      p.dispose();
      return i;
    }

    for (var round = 0; round < 2; round++) {
      final blurred = await blur(
        image,
        (unit * 0.5 * (round == 0 ? 1 : 0.62)).clamp(0.5, 90),
      );
      image.dispose();
      final shader = program!.fragmentShader()
        ..setFloat(0, width.toDouble())
        ..setFloat(1, height.toDouble())
        ..setFloat(
          2,
          round == 0
              ? 0.1
              : heat
              ? 0.2
              : 0.3,
        )
        ..setImageSampler(0, blurred);
      recorder = ui.PictureRecorder();
      canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..shader = shader,
      );
      picture = recorder.endRecording();
      image = await picture.toImage(width, height);
      picture.dispose();
      shader.dispose();
      blurred.dispose();
    }
    final feathered = await blur(image, 1);
    image.dispose();
    final bytes = (await feathered.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    feathered.dispose();
    return BlobSheet(
      bytes,
      LatLngQuad(
        topLeft: LatLng(bounds[3], longitude(west)),
        topRight: LatLng(bounds[3], longitude(east)),
        bottomRight: LatLng(bounds[1], longitude(east)),
        bottomLeft: LatLng(bounds[1], longitude(west)),
      ),
    );
  }
}
