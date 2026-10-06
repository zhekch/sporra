import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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
        direction: DismissDirection.horizontal,
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
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: Material(
                  color: const Color(0xe6262626),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
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
                        CupertinoButton(
                          padding: const EdgeInsets.all(10),
                          minimumSize: Size.zero,
                          onPressed: dismissToast,
                          child: const Icon(
                            CupertinoIcons.xmark,
                            size: 16,
                            color: Colors.white70,
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
