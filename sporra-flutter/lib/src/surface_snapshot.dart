import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import 'closing_blur.dart';

const _minCaptureInterval = Duration(milliseconds: 80);

const _surfaceChannel = MethodChannel('sporra/surfaces');

/// Cache the composed surface while open: a Flutter ImageFiltered cannot blur
/// the UIKit backdrop behind a platform map. Its snapshot can be blurred whole.
class SurfaceSnapshot extends StatefulWidget {
  const SurfaceSnapshot({super.key, required this.shape, required this.child});
  final ShapeBorder shape;
  final Widget child;

  @override
  State<SurfaceSnapshot> createState() => _SurfaceSnapshotState();
}

class _SurfaceSnapshotState extends State<SurfaceSnapshot> {
  ui.Image? image;
  Size? imageSize;
  double sigma = 0;
  bool settledOpen = false;
  bool queued = false;
  bool capturing = false;
  bool watchingFrames = false;
  DateTime? lastCapture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = context
        .dependOnInheritedWidgetOfExactType<ClosingBlurScope>();
    sigma = scope?.sigma ?? 0;
    settledOpen = scope?.settledOpen == true && scope?.snapshotSurfaces == true;
    if (scope?.snapshotSurfaces == true && !watchingFrames) {
      SchedulerBinding.instance.addTimingsCallback(onFrame);
      watchingFrames = true;
    }
    if (sigma == 0 && settledOpen) scheduleCapture();
  }

  void onFrame(List<ui.FrameTiming> _) {
    if (mounted && sigma == 0 && settledOpen) capture();
  }

  void scheduleCapture() {
    if (queued || capturing || sigma != 0 || !settledOpen) return;
    queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      queued = false;
      if (mounted && sigma == 0 && settledOpen) capture();
    });
  }

  Future<ui.Image?> grab(Rect rect, ui.FlutterView view) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final bytes = await _surfaceChannel.invokeMethod<Uint8List>('capture', {
          'x': rect.left,
          'y': rect.top,
          'width': rect.width,
          'height': rect.height,
          'scale': view.devicePixelRatio,
        });
        if (bytes != null) {
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          codec.dispose();
          return frame.image;
        }
        return null;
      } on MissingPluginException {
        // Pure Flutter test hosts and non-native embeddings use the scene below.
      } on PlatformException {
        return null;
      }
    }
    final root = RendererBinding.instance.renderViews.firstWhere(
      (root) => root.flutterView == view,
    );
    // The whole scene is needed so the surface's backdrop can sample its map.
    // ignore: invalid_use_of_protected_member
    final scene = root.layer!.buildScene(ui.SceneBuilder());
    final full = await scene.toImage(
      view.physicalSize.width.ceil(),
      view.physicalSize.height.ceil(),
    );
    scene.dispose();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final ratio = view.devicePixelRatio;
    canvas.drawImageRect(
      full,
      Rect.fromLTWH(
        rect.left * ratio,
        rect.top * ratio,
        rect.width * ratio,
        rect.height * ratio,
      ),
      Rect.fromLTWH(0, 0, rect.width * ratio, rect.height * ratio),
      Paint(),
    );
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(
      (rect.width * ratio).ceil(),
      (rect.height * ratio).ceil(),
    );
    picture.dispose();
    full.dispose();
    return cropped;
  }

  Future<void> capture({bool force = false}) async {
    if (capturing || !mounted || sigma != 0 || !settledOpen) return;
    if (!force &&
        lastCapture != null &&
        DateTime.now().difference(lastCapture!) < _minCaptureInterval) {
      return;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return;
    final size = box.size;
    final shape = widget.shape;
    final rect = box.localToGlobal(Offset.zero) & size;
    final view = View.of(context);
    final viewport = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    if (rect.left < viewport.left ||
        rect.top < viewport.top ||
        rect.right > viewport.right ||
        rect.bottom > viewport.bottom) {
      return;
    }
    capturing = true;
    lastCapture = DateTime.now();
    ui.Image? next;
    try {
      next = await grab(rect, view);
    } catch (error) {
      if (kDebugMode) debugPrint('Menu snapshot unavailable: $error');
    } finally {
      capturing = false;
    }
    if (next == null) return;
    if (!mounted) {
      next.dispose();
      return;
    }
    // A native capture can finish after dismissal starts. Keep the open frame
    // frozen rather than replacing it with pixels from the closing animation.
    final currentBox = context.findRenderObject();
    if ((sigma > 0 && image != null) ||
        widget.shape != shape ||
        currentBox is! RenderBox ||
        !currentBox.hasSize ||
        currentBox.size != size) {
      next.dispose();
      return;
    }
    final old = image;
    image = next;
    imageSize = size;
    if (sigma > 0) setState(() {});
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void dispose() {
    if (watchingFrames) {
      SchedulerBinding.instance.removeTimingsCallback(onFrame);
    }
    image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = context.findRenderObject();
    final size = box is RenderBox && box.hasSize ? box.size : null;
    final useSnapshot = sigma > 0 && image != null && imageSize == size;
    return Listener(
      onPointerDown: (_) {
        if (sigma == 0) capture(force: true);
      },
      child: _PaintObserver(
        onPaint: scheduleCapture,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Opacity(
              opacity: useSnapshot ? 0 : 1,
              alwaysIncludeSemantics: true,
              child: widget.child,
            ),
            if (useSnapshot)
              Positioned.fill(
                child: IgnorePointer(
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: sigma,
                      sigmaY: sigma,
                      tileMode: ui.TileMode.decal,
                    ),
                    child: ClipPath(
                      clipper: ShapeBorderClipper(shape: widget.shape),
                      child: RawImage(image: image, fit: BoxFit.fill),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PaintObserver extends SingleChildRenderObjectWidget {
  const _PaintObserver({required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintObserver(onPaint);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPaintObserver renderObject,
  ) => renderObject.onPaint = onPaint;
}

class _RenderPaintObserver extends RenderProxyBox {
  _RenderPaintObserver(this.onPaint);
  VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }
}
