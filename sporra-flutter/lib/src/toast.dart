import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'appearance.dart';

const persistentErrorDelay = Duration(seconds: 3);

// Toasts live above sheets too, and a replacement never leaves an old timer
// able to dismiss the new message.
OverlayEntry? _entry;
Timer? _timer;
void showToast(
  BuildContext context,
  String message, {
  double top = 12,
  String? action,
  VoidCallback? onAction,
}) {
  _timer?.cancel();
  _entry?.remove();
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      top: MediaQuery.paddingOf(context).top + top,
      left: 16,
      right: 16,
      child: Dismissible(
        key: UniqueKey(),
        direction: DismissDirection.vertical,
        onDismissed: (_) => dismissToast(),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, -16 * (1 - t)),
              child: child,
            ),
          ),
          child: Center(
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(menuCornerRadius(context)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: Material(
                  color: const Color(0xe6262626),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (action != null)
                          CupertinoButton(
                            padding: const EdgeInsets.all(10),
                            minimumSize: Size.zero,
                            onPressed: () {
                              dismissToast();
                              onAction?.call();
                            },
                            child: Text(
                              action,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  _entry = entry;
  Overlay.of(context, rootOverlay: true).insert(entry);
  _timer = Timer(const Duration(seconds: 5), dismissToast);
}

void dismissToast() {
  _timer?.cancel();
  _timer = null;
  _entry?.remove();
  _entry = null;
}

// A brief failed request is often followed immediately by a successful one.
// Keep the notice quiet until the failure survives a recovery window.
class DelayedErrorNotice extends StatefulWidget {
  const DelayedErrorNotice({
    super.key,
    required this.message,
    required this.builder,
  });
  final String? message;
  final Widget Function(String message) builder;
  @override
  State<DelayedErrorNotice> createState() => _DelayedErrorNoticeState();
}

class _DelayedErrorNoticeState extends State<DelayedErrorNotice> {
  Timer? timer;
  bool visible = false;
  @override
  void initState() {
    super.initState();
    update();
  }

  @override
  void didUpdateWidget(DelayedErrorNotice old) {
    super.didUpdateWidget(old);
    update();
  }

  void update() {
    if (widget.message == null) {
      timer?.cancel();
      timer = null;
      visible = false;
    } else if (!visible && timer == null) {
      timer = Timer(persistentErrorDelay, () {
        timer = null;
        if (mounted && widget.message != null) setState(() => visible = true);
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => visible && widget.message != null
      ? widget.builder(widget.message!)
      : const SizedBox.shrink();
}
