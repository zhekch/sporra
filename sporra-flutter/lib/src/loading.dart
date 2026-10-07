import 'dart:math' as math;

import 'package:flutter/material.dart';

// A steady ring with one moving arc, matching the loading reference. The
// animation keeps its shape instead of growing and shrinking while data loads.
class LoadingIndicator extends StatefulWidget {
  const LoadingIndicator({
    super.key,
    this.label = 'Loading…',
    this.showLabel = true,
  });
  final String label;
  final bool showLabel;
  @override
  State<LoadingIndicator> createState() => _LoadingIndicatorState();
}

class _LoadingIndicatorState extends State<LoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      rotation.stop();
    } else if (!rotation.isAnimating) {
      rotation.repeat();
    }
  }

  @override
  void dispose() {
    rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const ink = Colors.white;
    final spinner = RotationTransition(
      turns: rotation,
      child: SizedBox.square(
        dimension: 24,
        child: CustomPaint(painter: _LoadingRing(ink)),
      ),
    );
    if (!widget.showLabel) {
      return Semantics(label: widget.label, child: spinner);
    }
    return Semantics(
      liveRegion: true,
      label: widget.label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              spinner,
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingRing extends CustomPainter {
  const _LoadingRing(this.ink);
  final Color ink;
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = (Offset.zero & size).deflate(2);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(
      bounds,
      ring
        ..color = ink.withValues(alpha: 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    ring.maskFilter = null;
    canvas.drawOval(bounds, ring..color = ink.withValues(alpha: 0.28));
    canvas.drawArc(bounds, -math.pi / 4, math.pi / 3, false, ring..color = ink);
  }

  @override
  bool shouldRepaint(_LoadingRing old) => old.ink != ink;
}
