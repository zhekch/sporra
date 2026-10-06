import 'dart:math' as math;

import 'package:flutter/material.dart';

class YearChart extends StatefulWidget {
  const YearChart({super.key, required this.entries});
  final List<Map<String, dynamic>> entries;
  @override
  State<YearChart> createState() => _YearChartState();
}

class _YearChartState extends State<YearChart> {
  int? selected;
  @override
  Widget build(BuildContext context) {
    final max = widget.entries.fold<double>(
      1,
      (max, e) => math.max(max, (e['value'] as num).toDouble()),
    );
    return Column(
      children: [
        SizedBox(
          height: 24,
          child: Text(
            selected == null
                ? 'Tap a year to inspect'
                : '${widget.entries[selected!]['year']} · ${widget.entries[selected!]['label']}',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ),
        SizedBox(
          height: 125,
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < widget.entries.length; i++)
                    Semantics(
                      label:
                          '${widget.entries[i]['year']}: ${widget.entries[i]['label']}',
                      selected: i == selected,
                      button: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => selected = i),
                        child: SizedBox(
                          width: math.max(
                            44,
                            constraints.maxWidth / widget.entries.length,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                width: 26,
                                height: math.max(
                                  3,
                                  (widget.entries[i]['value'] as num) /
                                      max *
                                      100,
                                ),
                                decoration: BoxDecoration(
                                  color: i == selected
                                      ? Colors.white70
                                      : Colors.white24,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                '${widget.entries[i]['year']}'.substring(2),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white60,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
