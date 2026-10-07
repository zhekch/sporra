import 'package:flutter/material.dart';

import 'appearance.dart';
import 'state.dart';

const railGroups = {
  'linenumbers': 'Line numbers',
  'tracks': 'Tracks',
  'stations': 'Stations',
  'symbols': 'Signals & crossings',
  'platforms': 'Platforms',
  'milestones': 'Kilometre posts',
};

class RailSettings extends StatelessWidget {
  const RailSettings({super.key, required this.app});
  final AppState app;
  Future<void> save(Map<String, dynamic> patch) => app.run(() async {
    final previous = app.prefs;
    try {
      await app.patchPrefs(patch);
    } catch (_) {
      app.prefs = previous;
      rethrow;
    }
    app.changed();
  });
  @override
  Widget build(BuildContext context) => DisclosureTile(
    title: const Text('Train track options'),
    children: [
      for (final group in railGroups.entries)
        GlassSwitch(
          title: Text(group.value),
          value: app.railGroupOn(group.key),
          onChanged: app.busy
              ? null
              : (value) => save({
                  'railGroups': {
                    ...?app.prefs['railGroups'] as Map?,
                    group.key: value,
                  },
                }),
        ),
      GlassSwitch(
        title: const Text('Technical infrastructure'),
        subtitle: const Text(
          'Proposed, construction, disused and service tracks',
        ),
        value: app.railTechnical,
        onChanged: app.busy ? null : (value) => save({'railTechnical': value}),
      ),
    ],
  );
}
