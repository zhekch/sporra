import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/closing_blur_test.dart' as menu_tests;

// Native capture keeps backdrop shaders in their actual viewport coordinates;
// re-rendering a subtree into toImage changes the backdrop input framebuffer.
Future<ByteData> nativePixels(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  RenderRepaintBoundary boundary,
  String name,
) async {
  await tester.pump(const Duration(milliseconds: 50));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  final bytes = await binding.takeScreenshot(name);
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  final image = (await codec.getNextFrame()).image;
  final source = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final origin = boundary.localToGlobal(Offset.zero);
  final ratio =
      image.width /
      (tester.view.physicalSize.width / tester.view.devicePixelRatio);
  final width = boundary.size.width.round();
  final height = boundary.size.height.round();
  final cropped = ByteData(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final sx = ((origin.dx + x + 0.5) * ratio).floor().clamp(
        0,
        image.width - 1,
      );
      final sy = ((origin.dy + y + 0.5) * ratio).floor().clamp(
        0,
        image.height - 1,
      );
      cropped.setUint32(
        (y * width + x) * 4,
        source.getUint32((sy * image.width + sx) * 4),
      );
    }
  }
  image.dispose();
  codec.dispose();
  return cropped;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var frame = 0;
  menu_tests.main(
    nativePixels: (tester, boundary) =>
        nativePixels(binding, tester, boundary, 'menu-pixel-${frame++}'),
    onFeatheredFrame: (tester) async {
      await tester.pump(const Duration(milliseconds: 50));
      await binding.takeScreenshot('menu-feathered-edge');
    },
  );
}
