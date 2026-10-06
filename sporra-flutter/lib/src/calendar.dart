import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

String dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class VisitCalendar extends StatefulWidget {
  const VisitCalendar({
    super.key,
    required this.days,
    required this.trips,
    required this.onPick,
    this.selected,
  });
  final Map days;
  final List trips;
  final ValueChanged<DateTime> onPick;
  final String? selected;
  @override
  State<VisitCalendar> createState() => _VisitCalendarState();
}

class _VisitCalendarState extends State<VisitCalendar> {
  late DateTime month;
  static const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  @override
  void initState() {
    super.initState();
    final selected = DateTime.tryParse(widget.selected ?? '') ?? DateTime.now();
    month = DateTime(selected.year, selected.month);
  }

  dynamic tripAt(DateTime day) {
    for (final trip in widget.trips) {
      final start = DateTime.fromMillisecondsSinceEpoch(
        (trip['start'] as num).toInt() * 1000,
      );
      final end = DateTime.fromMillisecondsSinceEpoch(
        (trip['end'] as num).toInt() * 1000,
      );
      if (dayKey(day).compareTo(dayKey(start)) >= 0 &&
          dayKey(day).compareTo(dayKey(end)) <= 0) {
        return trip;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final count = DateTime(month.year, month.month + 1, 0).day;
    final offset = (month.weekday - 1) % 7;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            CupertinoButton(
              onPressed: () =>
                  setState(() => month = DateTime(month.year, month.month - 1)),
              child: const Icon(CupertinoIcons.chevron_left, size: 18),
            ),
            Expanded(
              child: Center(
                child: Text(
                  '${months[month.month - 1]} ${month.year}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            CupertinoButton(
              onPressed: () =>
                  setState(() => month = DateTime(month.year, month.month + 1)),
              child: const Icon(CupertinoIcons.chevron_right, size: 18),
            ),
          ],
        ),
        Row(
          children: [
            for (final name in [
              'Mon',
              'Tue',
              'Wed',
              'Thu',
              'Fri',
              'Sat',
              'Sun',
            ])
              Expanded(
                child: Center(
                  child: Text(
                    name,
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        for (var week = 0; week < ((count + offset) / 7).ceil(); week++)
          Row(
            children: [
              for (var weekday = 0; weekday < 7; weekday++)
                Expanded(
                  child: dayCell(
                    week * 7 + weekday - offset + 1,
                    count,
                    weekday,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget dayCell(int number, int count, int weekday) {
    if (number < 1 || number > count) return const SizedBox(height: 42);
    final day = DateTime(month.year, month.month, number),
        key = dayKey(DateTime(month.year, month.month, number));
    final visit = widget.days[key];
    final trip = tripAt(day);
    final left =
        number > 1 &&
        weekday > 0 &&
        trip != null &&
        tripAt(day.subtract(const Duration(days: 1))) == trip;
    final right =
        number < count &&
        weekday < 6 &&
        trip != null &&
        tripAt(day.add(const Duration(days: 1))) == trip;
    final picked = widget.selected == key;
    return Semantics(
      excludeSemantics: true,
      button: true,
      selected: picked,
      label:
          '$key${trip == null ? '' : ' · ${trip['name']}'}${visit == null ? '' : ' · ${visit['routes']} activities'}',
      child: GestureDetector(
        onTap: () => widget.onPick(day),
        child: Container(
          height: 42,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: picked
                ? const Color(0x665facff)
                : trip != null
                ? const Color(0x22ffcf4d)
                : Colors.transparent,
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(left ? 0 : 12),
              right: Radius.circular(right ? 0 : 12),
            ),
            border: key == dayKey(DateTime.now())
                ? Border.all(color: Colors.white24)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$number',
                style: TextStyle(
                  fontSize: 14,
                  color: visit != null || picked
                      ? Colors.white
                      : Colors.white38,
                ),
              ),
              const SizedBox(height: 3),
              Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: visit == null
                      ? Colors.transparent
                      : (visit['routes'] as num? ?? 0) > 0
                      ? const Color(0xffffcf4d)
                      : const Color(0xff60acff),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
