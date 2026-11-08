import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// UIKit supplies the installed system symbols; no Apple font or image assets
// are bundled or exported to other platforms.
class SFIcon extends StatelessWidget {
  const SFIcon(
    this.name, {
    super.key,
    required this.fallback,
    this.size,
    this.color,
    this.weight = FontWeight.w400,
  });
  final String name;
  final IconData fallback;
  final double? size;
  final Color? color;
  final FontWeight weight;
  static const channel = MethodChannel('sporra/symbols');
  static final _images = <(String, double, double, int), Future<Uint8List?>>{};
  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final dimension = size ?? theme.size ?? 24;
    final base = color ?? theme.color ?? Colors.white;
    final ink = base.withValues(alpha: base.a * (theme.opacity ?? 1));
    final placeholder = Icon(fallback, size: dimension, color: color);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return placeholder;
    }
    final scale = MediaQuery.devicePixelRatioOf(context);
    final image = _images.putIfAbsent(
      (name, dimension, scale, weight.value),
      () async {
        try {
          return await channel.invokeMethod<Uint8List>('render', {
            'name': name,
            'size': dimension,
            'scale': scale,
            'weight': weight.value,
          });
        } on PlatformException {
          return null;
        } on MissingPluginException {
          return null;
        }
      },
    );
    return SizedBox.square(
      dimension: dimension,
      child: FutureBuilder<Uint8List?>(
        future: image,
        builder: (_, result) => result.data == null
            ? placeholder
            : Image.memory(
                result.data!,
                width: dimension,
                height: dimension,
                color: ink,
                colorBlendMode: BlendMode.srcIn,
                gaplessPlayback: true,
                excludeFromSemantics: true,
              ),
      ),
    );
  }
}
