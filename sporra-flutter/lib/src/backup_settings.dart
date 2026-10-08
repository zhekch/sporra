import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'appearance.dart';
import 'loading.dart';
import 'sheets.dart' show IOSPicker, fact;
import 'state.dart';

class BackupSchedule {
  BackupSchedule({
    this.preset = 'daily',
    this.hour = 4,
    this.minute = 0,
    this.weekday = 1,
    this.day = 1,
    this.custom = '',
  });
  String preset, custom;
  int hour, minute, weekday, day;
  factory BackupSchedule.parse(String cron) {
    final s = BackupSchedule(preset: 'custom', custom: cron);
    final parts = cron.trim().split(RegExp(r'\s+'));
    if (parts.length != 5 || parts[3] != '*') return s;
    final m = int.tryParse(parts[0]);
    if (m == null || m < 0 || m > 59) return s;
    s.minute = m;
    if (parts[2] == '*' && parts[4] == '*') {
      if (parts[1] == '*') {
        s.preset = 'hourly';
        return s;
      }
      if (parts[1] == '*/6') {
        s.preset = 'six';
        return s;
      }
    }
    final h = int.tryParse(parts[1]);
    if (h == null || h < 0 || h > 23) return s;
    s.hour = h;
    if (parts[2] == '*' && parts[4] == '*') {
      s.preset = 'daily';
    } else if (parts[2] == '*' && int.tryParse(parts[4]) != null) {
      final day = int.parse(parts[4]);
      if (day >= 0 && day <= 7) {
        s.preset = 'weekly';
        s.weekday = day % 7;
      }
    } else if (parts[4] == '*' && int.tryParse(parts[2]) != null) {
      final day = int.parse(parts[2]);
      if (day >= 1 && day <= 31) {
        s.preset = 'monthly';
        s.day = day;
      }
    }
    return s;
  }
  String get cron => switch (preset) {
    'hourly' => '$minute * * * *',
    'six' => '$minute */6 * * *',
    'daily' => '$minute $hour * * *',
    'weekly' => '$minute $hour * * $weekday',
    'monthly' => '$minute $hour $day * *',
    _ => custom.trim(),
  };
}

String backupSize(num? bytes) {
  final n = bytes ?? 0;
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String backupTime(dynamic seconds, {String empty = 'Never'}) {
  if (seconds is! num || seconds == 0) return empty;
  final t = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round())
      .toLocal();
  String two(int n) => '$n'.padLeft(2, '0');
  return '${two(t.day)}.${two(t.month)}.${t.year} ${two(t.hour)}:${two(t.minute)}';
}

class BackupSettings extends StatefulWidget {
  const BackupSettings({
    super.key,
    required this.app,
    required this.fileBuilder,
  });
  final AppState app;
  final Widget Function(BuildContext, Map<String, dynamic>) fileBuilder;
  @override
  State<BackupSettings> createState() => _BackupSettingsState();
}

class _BackupSettingsState extends State<BackupSettings> {
  Map<String, dynamic>? status;
  BackupSchedule schedule = BackupSchedule();
  final custom = TextEditingController();
  bool enabled = true, loading = true, busy = false;
  int keep = 14;
  String? error, note;
  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    custom.dispose();
    super.dispose();
  }

  void fill(dynamic value) {
    status = Map<String, dynamic>.from(value);
    enabled = status!['enabled'] != false;
    keep = (status!['keep'] as num?)?.toInt() ?? 14;
    schedule = BackupSchedule.parse('${status!['cron'] ?? '0 4 * * *'}');
    custom.text = schedule.custom;
  }

  Future<void> reload() async {
    try {
      final result = await widget.app.api.get('/api/backup');
      if (mounted) {
        setState(() {
          fill(result['backup']);
          error = null;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> execute(bool run) async {
    setState(() {
      busy = true;
      error = null;
      note = null;
    });
    try {
      final result = await widget.app.api.post(
        run ? '/api/backup/run' : '/api/backup',
        run ? {} : {'enabled': enabled, 'cron': schedule.cron, 'keep': keep},
      );
      if (!mounted) return;
      setState(() {
        fill(result['backup']);
        if (!run) {
          note = 'Schedule saved.';
        } else if (result['status'] == 'error') {
          error = '${result['error'] ?? 'Backup failed.'}';
        } else if (result['status'] == 'saved') {
          note =
              'Backed up — ${backupSize(result['size'] as num?)}'
              '${(result['pruned'] as num? ?? 0) > 0 ? ', ${result['pruned']} older backups removed' : ''}.';
        } else {
          note =
              'Nothing to back up — ${result['reason'] ?? 'the map has not changed'}.';
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pickTime() async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => Container(
        height: 300,
        color: const Color(0xff262626),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: CupertinoButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.time,
                  use24hFormat: MediaQuery.alwaysUse24HourFormatOf(context),
                  initialDateTime: DateTime(
                    2026,
                    1,
                    1,
                    schedule.hour,
                    schedule.minute,
                  ),
                  onDateTimeChanged: (time) => setState(() {
                    schedule.hour = time.hour;
                    schedule.minute = time.minute;
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: LoadingIndicator(showLabel: false),
      );
    }
    if (status == null) {
      return Column(
        children: [
          Text(error ?? 'Backups unavailable'),
          TextButton(onPressed: reload, child: const Text('Retry')),
        ],
      );
    }
    final data = status!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassSwitch(
          title: const Text('Back up automatically'),
          value: enabled,
          onChanged: busy ? null : (v) => setState(() => enabled = v),
        ),
        ListTile(
          title: const Text('How often'),
          trailing: IOSPicker<String>(
            value: schedule.preset,
            items: const [
              DropdownMenuItem(value: 'hourly', child: Text('Every hour')),
              DropdownMenuItem(value: 'six', child: Text('Every 6 hours')),
              DropdownMenuItem(value: 'daily', child: Text('Every day')),
              DropdownMenuItem(value: 'weekly', child: Text('Every week')),
              DropdownMenuItem(value: 'monthly', child: Text('Every month')),
              DropdownMenuItem(value: 'custom', child: Text('Custom…')),
            ],
            onChanged: busy
                ? null
                : (v) => setState(() {
                    schedule.custom = schedule.cron;
                    custom.text = schedule.custom;
                    schedule.preset = v!;
                  }),
          ),
        ),
        if (!['hourly', 'six', 'custom'].contains(schedule.preset))
          ListTile(
            title: const Text('At'),
            subtitle: const Text('Server time'),
            trailing: TextButton(
              onPressed: busy ? null : pickTime,
              child: Text(
                '${schedule.hour.toString().padLeft(2, '0')}:${schedule.minute.toString().padLeft(2, '0')}',
              ),
            ),
          ),
        if (schedule.preset == 'weekly')
          ListTile(
            title: const Text('On'),
            trailing: IOSPicker<int>(
              value: schedule.weekday,
              items: [
                for (final day in const {
                  0: 'Sunday',
                  1: 'Monday',
                  2: 'Tuesday',
                  3: 'Wednesday',
                  4: 'Thursday',
                  5: 'Friday',
                  6: 'Saturday',
                }.entries)
                  DropdownMenuItem(value: day.key, child: Text(day.value)),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() => schedule.weekday = v!),
            ),
          ),
        if (schedule.preset == 'monthly')
          ListTile(
            title: const Text('Day of month'),
            trailing: IOSPicker<int>(
              value: schedule.day,
              items: [
                for (final day in ({
                  1,
                  5,
                  10,
                  15,
                  20,
                  25,
                  28,
                  schedule.day,
                }.toList()..sort()))
                  DropdownMenuItem(value: day, child: Text('$day')),
              ],
              onChanged: busy ? null : (v) => setState(() => schedule.day = v!),
            ),
          ),
        if (schedule.preset == 'custom')
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: TextField(
              controller: custom,
              enabled: !busy,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Cron schedule',
                hintText: 'minute hour day month weekday',
              ),
              onChanged: (v) => setState(() => schedule.custom = v),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Text(
            schedule.cron == data['cron']
                ? '${data['description'] ?? schedule.cron}'
                : schedule.cron,
            style: const TextStyle(color: Colors.white60),
          ),
        ),
        ListTile(
          title: const Text('Keep'),
          trailing: IOSPicker<int>(
            value: keep,
            items: [
              for (final n in ({3, 7, 14, 30, 90, keep}.toList()..sort()))
                DropdownMenuItem(value: n, child: Text('$n backups')),
            ],
            onChanged: busy ? null : (v) => setState(() => keep = v!),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: busy || schedule.cron.isEmpty
                      ? null
                      : () => execute(false),
                  child: const Text('Save schedule'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : () => execute(true),
                  child: Text(busy ? 'Working…' : 'Back up now on the server'),
                ),
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              error!,
              style: const TextStyle(color: CupertinoColors.systemRed),
            ),
          ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(note!),
          ),
        fact(
          'Last backup',
          '${backupTime(data['lastOk'])}${data['lastSize'] is num && data['lastSize'] > 0 ? ' · ${backupSize(data['lastSize'])}' : ''}',
        ),
        fact('Last check', backupTime(data['lastRun'])),
        fact(
          'Next backup',
          backupTime(data['nextRun'], empty: 'Not scheduled'),
        ),
        fact(
          'Kept / unchanged',
          '${data['runs'] ?? 0} kept · ${data['skips'] ?? 0} skipped',
        ),
        if ('${data['lastError'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              '${data['lastError']}',
              style: const TextStyle(color: CupertinoColors.systemRed),
            ),
          ),
        if (data['dir'] != null) fact('Backup folder', data['dir']),
        ListTile(
          title: const Text('Refresh status'),
          onTap: busy ? null : reload,
        ),
        for (final file in data['files'] as List? ?? [])
          widget.fileBuilder(context, Map<String, dynamic>.from(file)),
      ],
    );
  }
}
