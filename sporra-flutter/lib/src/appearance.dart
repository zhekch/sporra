import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

// SafeArea removes padding from submenu contexts; the view keeps the phone's
// original inset so every menu uses the same corner shape.
double menuCornerRadius(BuildContext context) {
  final view = View.of(context);
  return view.viewPadding.top / view.devicePixelRatio >= 44 ? 43 : 24;
}

RoundedSuperellipseBorder menuShape(BuildContext context) =>
    RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(menuCornerRadius(context)),
    );

ThemeData webTheme({double menuRadius = 24}) {
  const surface = Color(0xff262626);
  const accent = Color(0xff60acff);
  return ThemeData(
    brightness: Brightness.dark,
    platform: TargetPlatform.iOS,
    useMaterial3: false,
    fontFamily: '.SF Pro Text',
    scaffoldBackgroundColor: const Color(0xff0b0b0b),
    colorScheme: const ColorScheme.dark(
      primary: accent,
      secondary: accent,
      surface: surface,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.iOS: CupertinoPageTransitionsBuilder()},
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.white10,
    dividerColor: Colors.white12,
    expansionTileTheme: const ExpansionTileThemeData(
      textColor: Colors.white,
      collapsedTextColor: Colors.white,
      iconColor: Colors.white70,
      collapsedIconColor: Colors.white70,
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 14, height: 1.4),
      titleMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      headlineSmall: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 20),
      minVerticalPadding: 4,
      dense: true,
      iconColor: Colors.white70,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: Colors.white, iconSize: 21),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white12,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(menuRadius),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.05),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white12),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white12),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white54),
      ),
    ),
  );
}

class GlassSwitch extends StatelessWidget {
  const GlassSwitch({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => ListTile(
    title: title,
    subtitle: subtitle,
    trailing: Transform.scale(
      scale: 0.8,
      child: CupertinoSwitch(
        value: value,
        onChanged: onChanged,
        activeTrackColor: const Color(0xff727272),
      ),
    ),
    onTap: onChanged == null ? null : () => onChanged!(!value),
  );
}

class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.onReselected,
  });
  final VoidCallback? onReselected;
  final String? label;
  final String value;
  final Map<String, String> choices;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null) ...[
          Text(
            label!,
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
          const SizedBox(height: 8),
        ],
        CupertinoSlidingSegmentedControl<String>(
          groupValue: choices.containsKey(value) ? value : null,
          backgroundColor: Colors.white.withValues(alpha: 0.05),
          thumbColor: const Color(0xff484848),
          children: {
            for (final c in choices.entries)
              c.key: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: GestureDetector(
                  onTap: c.key == value ? onReselected : null,
                  child: Text(
                    c.value,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: c.key == value
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: c.key == value ? Colors.white : Colors.white60,
                    ),
                  ),
                ),
              ),
          },
          onValueChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    ),
  );
}
