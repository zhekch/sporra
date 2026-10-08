import 'dart:ui';

import 'package:flutter/material.dart';

// Closing progress: sharp at rest, gentle initially, then a softer exit.
final _blurFrames = TweenSequence<double>([
  TweenSequenceItem(tween: Tween(begin: 0, end: 2), weight: 35),
  TweenSequenceItem(tween: Tween(begin: 2, end: 8), weight: 35),
  TweenSequenceItem(tween: Tween(begin: 8, end: 18), weight: 30),
]);

class ClosingBlurScope extends InheritedWidget {
  const ClosingBlurScope({
    super.key,
    required this.sigma,
    this.settledOpen = true,
    this.snapshotSurfaces = true,
    required super.child,
  });

  final double sigma;
  final bool settledOpen;
  final bool snapshotSurfaces;

  static double sigmaOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ClosingBlurScope>()?.sigma ??
      0;

  @override
  bool updateShouldNotify(ClosingBlurScope oldWidget) =>
      sigma != oldWidget.sigma ||
      settledOpen != oldWidget.settledOpen ||
      snapshotSurfaces != oldWidget.snapshotSurfaces;
}

class ClosingBlur extends StatefulWidget {
  const ClosingBlur({
    super.key,
    required this.child,
    this.animation,
    this.filterChild = true,
  });
  final Widget child;
  final Animation<double>? animation;
  final bool filterChild;
  @override
  State<ClosingBlur> createState() => _ClosingBlurState();
}

class _ClosingBlurState extends State<ClosingBlur> {
  Animation<double>? animation;
  double previous = 0;
  bool closing = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    bind();
  }

  @override
  void didUpdateWidget(covariant ClosingBlur oldWidget) {
    super.didUpdateWidget(oldWidget);
    bind();
  }

  void bind() {
    final next = widget.animation ?? ModalRoute.of(context)?.animation;
    if (identical(next, animation)) return;
    animation?.removeListener(update);
    animation = next;
    previous = next?.value ?? 1;
    closing = next?.status == AnimationStatus.reverse;
    next?.addListener(update);
  }

  void update() {
    final value = animation!.value;
    // A drag can change route progress without setting reverse status. Keep
    // the blur during a cancelled drag until the sheet settles open again.
    if (value < previous) closing = true;
    if (value == 1) closing = false;
    previous = value;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    animation?.removeListener(update);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = closing && !MediaQuery.disableAnimationsOf(context)
        ? (1.0 - (animation?.value ?? 1.0)).clamp(0.0, 1.0)
        : 0.0;
    final sigma = _blurFrames.transform(progress);
    if (!widget.filterChild) {
      return ClosingBlurScope(
        sigma: sigma,
        settledOpen: (animation?.value ?? 1) == 1,
        snapshotSurfaces: !widget.filterChild,
        child: widget.child,
      );
    }
    return ImageFiltered(
      enabled: sigma > 0,
      // Transparent samples let the entire surface feather into its surroundings.
      // Clamping repeats the boundary pixels and leaves a hard outer edge.
      imageFilter: ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.decal,
      ),
      child: ClosingBlurScope(
        sigma: sigma,
        settledOpen: (animation?.value ?? 1) == 1,
        snapshotSurfaces: !widget.filterChild,
        child: widget.child,
      ),
    );
  }
}

Future<T?> showClosingDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (context) => ClosingBlur(child: builder(context)),
);
