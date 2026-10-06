import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'state.dart';
import 'appearance.dart';
import 'blob.dart' show parseColor;
import 'sheets.dart' show date, showActivityDetails;

class ActivityCard extends StatelessWidget {
  const ActivityCard({super.key, required this.app});
  final AppState app;
  @override
  Widget build(BuildContext context) {
    final data = app.activity!;
    final route = Map<String, dynamic>.from(data['route']);
    final summary = data['summary'] as Map;
    final graphs = data['graphs'] as Map;
    final graph = graphs[app.activityMetric];
    final choices = <String, String>{
      if (graphs['speed'] != null) 'speed': 'Speed',
      if (graphs['elev'] != null) 'elev': 'Elevation',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${route['name']}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close activity',
                onPressed: app.closeActivity,
                icon: const Icon(CupertinoIcons.xmark, size: 18),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    '${route['sport']} · ${date(route['firstAt'])}',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                  child: Wrap(
                    spacing: 22,
                    runSpacing: 8,
                    children: [
                      _reading('Distance', '${summary['distance']}'),
                      if (summary['duration'] != null)
                        _reading('Duration', '${summary['duration']}'),
                      if (summary['averageSpeed'] != null)
                        _reading('Average', '${summary['averageSpeed']}'),
                      if ((route['elevUp'] as num? ?? 0) > 0)
                        _reading('Ascent', '${route['elevUp']} m'),
                    ],
                  ),
                ),
                if (choices.isNotEmpty)
                  ChoiceRow(
                    label: 'Along the activity',
                    value: app.activityMetric!,
                    choices: choices,
                    onChanged: (metric) {
                      app.activityMetric = metric;
                      app.activitySample = null;
                      app.changed();
                    },
                  ),
                if (graph != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
                    child: ActivityGraph(
                      graph: Map<String, dynamic>.from(graph),
                      selected: app.activitySample,
                      onScrub: app.scrubActivity,
                    ),
                  ),
                if (choices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text(
                      'This activity has no recorded speed or elevation data.',
                      style: TextStyle(color: Colors.white60),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Row(
          children: [
            IconButton(
              tooltip: 'Previous activity',
              onPressed: app.busy
                  ? null
                  : () => app.run(() => app.stepActivity(-1)),
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: 'Next activity',
              onPressed: app.busy
                  ? null
                  : () => app.run(() => app.stepActivity(1)),
              icon: const Icon(Icons.chevron_right),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => showActivityDetails(context, app, route),
              child: const Text('More info'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _reading(String title, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontSize: 11, color: Colors.white54)),
      Text(
        value,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ],
  );
}

class ActivityGraph extends StatelessWidget {
  const ActivityGraph({
    super.key,
    required this.graph,
    this.selected,
    required this.onScrub,
  });
  final Map<String, dynamic> graph;
  final int? selected;
  final ValueChanged<int> onScrub;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final points = (graph['runs'] as List).expand((r) => r as List).toList();
      final chosen = points.where((p) => p['i'] == selected).firstOrNull;
      void scrub(Offset position) {
        final x =
            ((position.dx - 2) / (width - 4)).clamp(0.0, 1.0) *
            (graph['maxX'] as num);
        final nearest = points.reduce(
          (a, b) => ((a['x'] as num) - x).abs() <= ((b['x'] as num) - x).abs()
              ? a
              : b,
        );
        onScrub((nearest['i'] as num).toInt());
      }

      return Semantics(
        label:
            '${graph['metric'] == 'elev' ? 'Elevation' : 'Speed'} graph. Drag to inspect the activity on the map.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  '${graph['maxLabel'] ?? ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.white60),
                ),
                const Spacer(),
                if (chosen?['label'] != null)
                  Text(
                    '${chosen['label']}',
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Listener(
              onPointerDown: (e) => scrub(e.localPosition),
              onPointerMove: (e) => scrub(e.localPosition),
              child: SizedBox(
                height: 72,
                width: width,
                child: CustomPaint(painter: _GraphPainter(graph, selected)),
              ),
            ),
            SizedBox(
              height: 20,
              child: CustomPaint(painter: _AxisPainter(graph)),
            ),
          ],
        ),
      );
    },
  );
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.graph, this.selected);
  final Map<String, dynamic> graph;
  final int? selected;
  @override
  void paint(Canvas canvas, Size size) {
    final min = (graph['min'] as num).toDouble(),
        max = (graph['max'] as num).toDouble();
    double x(num value) =>
        2 + value / math.max(1, (graph['maxX'] as num)) * (size.width - 4);
    double y(num value) =>
        6 +
        (1 - (value - min) / (max == min ? 1 : max - min)) * (size.height - 12);
    for (final tick in graph['ticks']) {
      canvas.drawLine(
        Offset(x(tick['x']), 0),
        Offset(x(tick['x']), size.height),
        Paint()
          ..color = Colors.white12
          ..strokeWidth = 1,
      );
    }
    for (final run in graph['runs']) {
      for (var i = 1; i < (run as List).length; i++) {
        final a = run[i - 1], b = run[i];
        final start = Offset(x(a['x']), y(a['y'])),
            end = Offset(x(b['x']), y(b['y']));
        final color = b['color'] == null
            ? Colors.white60
            : parseColor(b['color']);
        canvas.drawPath(
          Path()
            ..moveTo(start.dx, start.dy)
            ..lineTo(end.dx, end.dy)
            ..lineTo(end.dx, size.height - 1)
            ..lineTo(start.dx, size.height - 1)
            ..close(),
          Paint()..color = color.withValues(alpha: 0.15),
        );
        canvas.drawLine(
          start,
          end,
          Paint()
            ..color = color
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }
      for (final p in run) {
        if (p['i'] == selected) {
          canvas.drawCircle(
            Offset(x(p['x']), y(p['y'])),
            4.5,
            Paint()..color = Colors.white,
          );
          canvas.drawCircle(
            Offset(x(p['x']), y(p['y'])),
            4.5,
            Paint()
              ..color = Colors.black54
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) =>
      old.graph != graph || old.selected != selected;
}

class _AxisPainter extends CustomPainter {
  _AxisPainter(this.graph);
  final Map<String, dynamic> graph;
  @override
  void paint(Canvas canvas, Size size) {
    TextPainter label(String text) => TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontSize: 11, color: Colors.white54),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final low = label('${graph['minLabel'] ?? ''}');
    low.paint(canvas, const Offset(0, 3));
    double right = low.width + 8;
    for (final tick in graph['ticks']) {
      final text = label(tick['label']);
      final x =
          2 +
          (tick['x'] as num) /
              math.max(1, (graph['maxX'] as num)) *
              (size.width - 4);
      if (x - text.width / 2 < right || x + text.width / 2 > size.width) {
        continue;
      }
      text.paint(canvas, Offset(x - text.width / 2, 3));
      right = x + text.width / 2 + 4;
    }
  }

  @override
  bool shouldRepaint(_AxisPainter old) => old.graph != graph;
}
