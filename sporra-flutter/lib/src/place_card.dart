import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'sheets.dart' show date;
import 'map_interaction.dart' show groupedNumber, formatGround, formatPercent;

class PlaceCard extends StatefulWidget {
  const PlaceCard({super.key, required this.info, required this.onClose});
  final Map<String, dynamic> info;
  final VoidCallback onClose;
  @override
  State<PlaceCard> createState() => _PlaceCardState();
}

class _PlaceCardState extends State<PlaceCard> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    // The immediate preview and older servers only retain the endpoints.
    final available =
        info['visitDates'] as List? ?? [info['firstAt'], info['lastAt']];
    final dates = available
        .where((v) => v != null && v != 0)
        .map(date)
        .toSet()
        .toList();
    final count = (info['visitCount'] as num?)?.toInt() ?? dates.length;
    final status = info['visited'] == null
        ? 'Loading visit details…'
        : info['visited'] != true
        ? 'Not visited yet'
        : dates.isEmpty
        ? 'You have been here'
        : '${groupedNumber(count)} ${count == 1 ? 'visit' : 'visits'}';
    final radius = BorderRadius.circular(40);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x8a262626),
            borderRadius: radius,
            border: Border.all(color: Colors.white12),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(26, 12, 14, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${info['name'] ?? 'This place'}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 4),
                              if (dates.isNotEmpty)
                                InkWell(
                                  onTap: () =>
                                      setState(() => expanded = !expanded),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Semantics(
                                    button: true,
                                    expanded: expanded,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 4,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              status,
                                              style: const TextStyle(
                                                fontSize: 13,
                                                color: Colors.white60,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          const Icon(
                                            CupertinoIcons.chevron_right,
                                            size: 12,
                                            color: Colors.white60,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                )
                              else
                                Text(
                                  status,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.white60,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Close place',
                          onPressed: widget.onClose,
                          icon: const Icon(CupertinoIcons.xmark, size: 18),
                        ),
                      ],
                    ),
                  ),
                  if (expanded && dates.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, 0, 26, 20),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * 0.3,
                        ),
                        child: ListView(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 4, bottom: 8),
                              child: Text(
                                'Recorded dates',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                            for (final value in dates)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 7,
                                ),
                                child: Text(
                                  value,
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (info['inside'] != null ||
                      (info['covered'] as num? ?? 0) > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, 0, 26, 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          [
                            if (info['inside'] != null)
                              '${info['inside']['label']} · ${groupedNumber(info['inside']['n'] as num)} of ${groupedNumber(info['inside']['of'] as num)}',
                            if ((info['covered'] as num? ?? 0) > 0)
                              'Ground covered · ${formatGround(info['covered'] as num)}${(info['coveredPct'] as num? ?? 0) > 0 ? ' · ${formatPercent(info['coveredPct'] as num)}' : ''}',
                          ].join('\n'),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white60,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
