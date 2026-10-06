import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

// Chrome lifts by the rendered card, including text scaling and landscape,
// rather than the card's maximum constraint.
class Measured extends SingleChildRenderObjectWidget {
  const Measured({super.key, required this.onSize, required super.child});
  final ValueChanged<Size> onSize;
  @override
  RenderObject createRenderObject(BuildContext context) => _Measured(onSize);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) => (renderObject as _Measured).onSize = onSize;
}

class _Measured extends RenderProxyBox {
  _Measured(this.onSize);
  ValueChanged<Size> onSize;
  Size? previous;
  @override
  void performLayout() {
    super.performLayout();
    if (previous == size) return;
    previous = size;
    final measured = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onSize(measured);
    });
  }
}
