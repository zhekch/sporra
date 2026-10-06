import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'state.dart';
import 'appearance.dart';
import 'blob.dart' show parseColor;
import 'year_chart.dart';

class Glass extends StatelessWidget {
  const Glass({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(20),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x8a262626),
          border: Border.all(color: Colors.white12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    ),
  );
}

Future<void> panel(BuildContext context, String title, Widget child) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            child: Glass(
              child: SizedBox(
                width: 520,
                height: MediaQuery.sizeOf(context).height * 0.82,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 8, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(child: child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
String date(dynamic value) {
  if (value == null || value == 0) return 'Unknown';
  final d = value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000)
      : DateTime.tryParse('$value');
  return d == null
      ? '$value'
      : '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

Widget section(String title) => Padding(
  padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
  child: Text(
    title.toUpperCase(),
    style: const TextStyle(
      fontSize: 12,
      color: Colors.white54,
      letterSpacing: 1.5,
    ),
  ),
);
Widget fact(String name, dynamic value) => ListTile(
  title: Text(name),
  trailing: Text('$value', style: const TextStyle(color: Colors.white70)),
);
Future<void> showInfo(BuildContext context, Map<String, dynamic> info) => panel(
  context,
  '${info['name'] ?? 'This place'}',
  ListView(
    children: [
      ListTile(
        leading: Icon(
          info['visited'] == true ? Icons.check_circle : Icons.circle_outlined,
        ),
        title: Text(
          info['visited'] == true ? 'You have been here' : 'No visits recorded',
        ),
      ),
      if (info['visited'] == true) ...[
        fact('Visits', info['hits'] == 0 ? 'Marked by hand' : info['hits']),
        fact('First seen', date(info['firstAt'])),
        fact('Last seen', date(info['lastAt'])),
      ],
      if (info['area'] != null) fact('Area', info['area']['kind']),
    ],
  ),
);

Future<void> showMenuSheet(
  BuildContext context,
  AppState app,
  VoidCallback refresh,
  MapLibreMapController? map,
) => panel(
  context,
  'Your map',
  Consumer(
    builder: (context, ref, _) {
      final a = ref.watch(appProvider);
      return ListView(
        children: [
          section('Appearance'),
          ChoiceRow(
            label: 'Basemap',
            value: a.style == 'satellite' ? 'satellite' : 'flat',
            choices: const {'flat': '2D', 'satellite': 'Satellite'},
            onChanged: (v) => a.setStyle(v == 'flat' ? 'dark' : v),
          ),
          if (a.style != 'satellite')
            ChoiceRow(
              label: 'Theme',
              value: a.style,
              choices: const {
                'dark': 'Dark',
                'terrain': 'Terrain',
                'voyager': 'Light',
              },
              onChanged: a.setStyle,
            ),
          ChoiceRow(
            label: 'Detail',
            value: a.detail,
            choices: const {
              'tiny': 'Tiniest',
              'auto': 'Auto',
              'region': 'Region',
              'country': 'Country',
              'continent': 'World',
            },
            onChanged: (v) {
              a.detail = v;
              a.changed();
            },
          ),
          ChoiceRow(
            label: 'Colouring',
            value: a.mode,
            choices: const {
              'flat': 'Single',
              'visits': 'Visits',
              'oldest': 'First seen',
              'type': 'Type',
            },
            onChanged: (v) {
              a.mode = v;
              a.changed();
              a.run(a.saveAppearance);
            },
          ),
          if (a.mode == 'flat')
            ListTile(
              title: const Text('Map colour'),
              trailing: ColorDot(a.accent),
              onTap: () async {
                final color = await chooseColor(context, a.accent);
                if (color != null) {
                  a.accent = color;
                  a.changed();
                  await a.run(a.saveAppearance);
                }
              },
            ),
          if (a.mode == 'visits' || a.mode == 'oldest')
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Column(
                children: [
                  Container(
                    height: 12,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      gradient: LinearGradient(
                        colors: a.mode == 'visits'
                            ? const [
                                Color(0xff2b3a6b),
                                Color(0xff39a0a0),
                                Color(0xfff2d049),
                                Color(0xffe4562f),
                              ]
                            : const [
                                Color(0xff5c2a3f),
                                Color(0xffcf8560),
                                Color(0xff79c39b),
                              ],
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(a.mode == 'visits' ? 'Rare' : 'Long ago'),
                      Text(a.mode == 'visits' ? 'Often' : 'Lately'),
                    ],
                  ),
                ],
              ),
            ),
          section('Your map'),
          GlassSwitch(
            title: const Text('Places answer a tap'),
            value: a.cellInfo,
            onChanged: (v) {
              a.cellInfo = v;
              a.changed();
            },
          ),

          GlassSwitch(
            title: const Text('Activities'),
            value: a.routes,
            onChanged: (v) {
              a.routes = v;
              a.changed();
            },
          ),
          ListTile(
            title: const Text('Activity colours and visibility'),
            leading: const Icon(Icons.palette_outlined),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => showActivityStyle(context, a),
          ),
          GlassSwitch(
            title: const Text('Photo pins'),
            subtitle: const Text('Pictures stay on your phone'),
            value: a.photos,
            onChanged: (v) {
              a.photos = v;
              a.changed();
            },
          ),
          ListTile(
            title: const Text('Browse activities'),
            leading: const Icon(Icons.route_outlined),
            onTap: () => showActivities(context, a, map),
          ),
          ListTile(
            title: const Text('Photos'),
            leading: const Icon(Icons.photo_library_outlined),
            onTap: () => showPhotos(context, a),
          ),
          section('Reference overlays'),
          GlassSwitch(
            title: const Text('Train tracks'),
            value: a.rail,
            onChanged: (v) {
              a.rail = v;
              a.changed();
            },
          ),
          GlassSwitch(
            title: const Text('Airports'),
            value: a.airports,
            onChanged: (v) {
              a.airports = v;
              a.changed();
            },
          ),
          GlassSwitch(
            title: const Text('Hiking trails'),
            value: a.trails,
            onChanged: (v) {
              a.trails = v;
              a.changed();
            },
          ),
          section('Explore and manage'),
          ListTile(
            leading: const Icon(Icons.bar_chart),
            title: const Text('Statistics'),
            onTap: () => showStats(context, a),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit your map'),
            onTap: () {
              a.editing = true;
              a.changed();
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: const Text('Sources'),
            onTap: () => showSources(context, a),
          ),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Import a location file'),
            subtitle: const Text('GPX, FIT, Timeline or a Strava archive'),
            onTap: () => importFile(context, a),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Sync connections'),
            onTap: () => showConnections(context, a),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Save map picture'),
            onTap: map == null
                ? null
                : () => a.run(() async {
                    final png = await map.takeSnapshot();
                    await a.native.saveImage(png);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Saved to Photos.')),
                      );
                    }
                  }),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () => showSettings(context, a),
          ),
          if (a.user?['admin'] == true || a.user?['isAdmin'] == true)
            ListTile(
              title: const Text('Administration'),
              leading: const Icon(Icons.admin_panel_settings_outlined),
              onTap: () => showAdmin(context, a),
            ),
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Sporra Preview · 0.2.0',
              style: TextStyle(color: Colors.white38),
            ),
          ),
        ],
      );
    },
  ),
);

class AsyncList extends StatefulWidget {
  const AsyncList({super.key, required this.load, required this.builder});
  final Future<dynamic> Function() load;
  final Widget Function(BuildContext, dynamic) builder;
  @override
  State<AsyncList> createState() => _AsyncListState();
}

class _AsyncListState extends State<AsyncList> {
  late Future<dynamic> future;
  @override
  void initState() {
    super.initState();
    future = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${snapshot.error}'),
                TextButton(
                  onPressed: () => setState(() => future = widget.load()),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      return widget.builder(context, snapshot.data);
    },
  );
}

Future<void> showStats(BuildContext context, AppState app) => panel(
  context,
  'Statistics',
  AsyncList(
    load: () => app.api.get('/api/stats'),
    builder: (context, s) => ListView(
      children: [
        fact('Ground covered', '${(s['km2'] as num).toStringAsFixed(1)} km²'),
        fact(
          'Countries',
          '${(s['countries'] as List).length} / ${s['countryTotal']}',
        ),
        fact('Days with visits', s['days']),
        fact('Longest streak', '${s['streakDays']} days'),
        fact('First seen', date(s['firstAt'])),
        fact('Last seen', date(s['lastAt'])),
        if ((s['years'] as List? ?? []).length > 1) ...[
          section('New ground by year'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: YearChart(
              entries: [
                for (final y in s['years'])
                  {'year': y[0], 'value': y[1], 'label': '${y[1]} cells'},
              ],
            ),
          ),
        ],
        section('Countries'),
        for (final c in s['countries'])
          ListTile(
            title: Text('${c['name'] ?? c['id']}'),
            subtitle: LinearProgressIndicator(
              value: ((c['pct'] as num?)?.toDouble() ?? 0).clamp(0, 100) / 100,
              minHeight: 3,
            ),
            trailing: Text('${(c['km2'] as num).toStringAsFixed(1)} km²'),
          ),
      ],
    ),
  ),
);
Future<void> showSources(BuildContext context, AppState app) => panel(
  context,
  'Sources',
  AsyncList(
    load: () => app.api.get('/api/sources'),
    builder: (context, data) => Consumer(
      builder: (context, ref, _) {
        ref.watch(appProvider);
        return ListView(
          children: [
            for (final s in data['sources'])
              GlassSwitch(
                title: Text('${s['key']}'),
                subtitle: Text(
                  '${s['cells']} cells · ${s['routes']} activities',
                ),
                value: !app.hidden.contains(s['key']),
                onChanged: (show) {
                  if (show == true) {
                    app.hidden.remove(s['key']);
                  } else {
                    app.hidden.add(s['key']);
                  }
                  app.changed();
                },
              ),
          ],
        );
      },
    ),
  ),
);
Future<void> showSporraSearch(
  BuildContext context,
  AppState app,
  MapLibreMapController map,
) => panel(context, 'Search', _Search(app: app, map: map));

class _Search extends StatefulWidget {
  const _Search({required this.app, required this.map});
  final AppState app;
  final MapLibreMapController map;
  @override
  State<_Search> createState() => _SearchState();
}

class _SearchState extends State<_Search> {
  List results = [];
  String? error;
  int generation = 0;
  bool busy = false;
  Future<void> search(String q) async {
    final token = ++generation;
    if (q.trim().length < 2) {
      setState(() => results = []);
      return;
    }
    setState(() => busy = true);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (token != generation) return;
    try {
      final data = await widget.app.api.get(
        '/api/search?q=${Uri.encodeQueryComponent(q)}',
      );
      if (mounted && token == generation) {
        setState(() {
          results = data['results'];
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted && token == generation) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: TextField(
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Places, regions, trips or activities',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: search,
        ),
      ),
      if (busy) const LinearProgressIndicator(),
      if (error != null)
        Padding(padding: const EdgeInsets.all(24), child: Text(error!)),
      Expanded(
        child: ListView(
          children: [
            for (final r in results)
              ListTile(
                title: Text('${r['name']}'),
                subtitle: Text(
                  '${r['kind']}${r['country'] == null ? '' : ' · ${r['country']}'}',
                ),
                onTap: () {
                  if (r['kind'] == 'route') {
                    showRoute(
                      context,
                      widget.app,
                      Map<String, dynamic>.from(r),
                    );
                  } else {
                    goTo(widget.map, r);
                    Navigator.pop(context);
                  }
                },
              ),
          ],
        ),
      ),
    ],
  );
}

void goTo(MapLibreMapController map, Map r, {double bottom = 150}) {
  final bounds = r['bbox'] ?? r['bounds'];
  if (bounds is List && bounds.length == 4) {
    map.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(
            (bounds[1] as num).toDouble(),
            (bounds[0] as num).toDouble(),
          ),
          northeast: LatLng(
            (bounds[3] as num).toDouble(),
            (bounds[2] as num).toDouble(),
          ),
        ),
        left: 50,
        right: 50,
        top: 100,
        bottom: bottom,
      ),
    );
  } else if (r['lng'] != null && r['lat'] != null) {
    map.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng((r['lat'] as num).toDouble(), (r['lng'] as num).toDouble()),
        12,
      ),
    );
  } else if (r['center'] is List) {
    map.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(
          (r['center'][1] as num).toDouble(),
          (r['center'][0] as num).toDouble(),
        ),
        9,
      ),
    );
  }
}

Future<void> showTrips(
  BuildContext context,
  AppState app,
  MapLibreMapController map,
) => panel(
  context,
  'Trips and days',
  AsyncList(
    load: () async => {
      'trips': (await app.api.get('/api/trips'))['trips'],
      'days': (await app.api.get('/api/days'))['days'],
    },
    builder: (context, data) => ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.calendar_month),
          title: const Text('Choose a day'),
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              firstDate: DateTime(1970),
              lastDate: DateTime.now(),
              initialDate: DateTime.now(),
            );
            if (d != null && context.mounted) {
              await showDay(
                context,
                app,
                '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
                map,
              );
            }
          },
        ),
        section('Trips'),
        for (final t in data['trips'])
          ListTile(
            title: Text('${t['name']}'),
            subtitle: Text(
              '${date(t['start'] ?? t['firstAt'])} – ${date(t['end'] ?? t['lastAt'])}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              goTo(map, t);
              Navigator.pop(context);
            },
          ),
        section('Recent days'),
        for (final key
            in ((data['days'] as Map).keys.map((e) => '$e').toList()..sort())
                .reversed
                .take(100))
          ListTile(
            title: Text(date(key)),
            subtitle: Text('${data['days'][key]['routes']} activities'),
            onTap: () => showDay(context, app, key, map),
          ),
      ],
    ),
  ),
);
Future<void> showDay(
  BuildContext context,
  AppState app,
  String key,
  MapLibreMapController map,
) => panel(
  context,
  date(key),
  AsyncList(
    load: () => app.api.get('/api/day/$key'),
    builder: (context, d) => ListView(
      children: [
        for (final r in d['routes'] ?? [])
          ListTile(
            title: Text('${r['name']}'),
            subtitle: Text('${r['sport'] ?? 'Activity'}'),
            onTap: () {
              showRoute(context, app, Map<String, dynamic>.from(r));
            },
          ),
        if ((d['routes'] ?? []).isEmpty)
          const ListTile(title: Text('No activities on this day.')),
      ],
    ),
  ),
);
Future<void> importFile(BuildContext context, AppState app) async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: [
      'gpx',
      'tcx',
      'kml',
      'json',
      'xml',
      'zip',
      'gz',
      'fit',
      'csv',
      'geojson',
    ],
  );
  if (result.isEmpty) return;
  await app.run(() async {
    final f = result.single;
    final bytes = await f.readAsBytes();
    final data = await app.api.post('/api/import/file', {
      'name': f.name,
      'base64': base64Encode(bytes),
    });
    app.changed();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Imported ${data['imported']} cells from ${f.name}.'),
        ),
      );
    }
  });
}

Future<void> showPhotos(BuildContext context, AppState app) => panel(
  context,
  'Photos',
  AsyncList(
    load: () async => jsonDecode(await app.native.photos()),
    builder: (context, items) {
      if ((items as List).isEmpty) {
        return const Center(
          child: Text('No located photos. Check access in iOS Settings.'),
        );
      }
      return GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) => GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PhotoGallery(app: app, photos: items, index: i),
            ),
          ),
          child: FutureBuilder(
            future: app.native.thumbnail(items[i]['index'], 256),
            builder: (_, s) => s.hasData
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(s.data!, fit: BoxFit.cover),
                      if (items[i]['video'] == true)
                        const Center(child: Icon(Icons.play_circle_fill)),
                    ],
                  )
                : const ColoredBox(color: Colors.white12),
          ),
        ),
      );
    },
  ),
);

class PhotoGallery extends StatefulWidget {
  const PhotoGallery({
    super.key,
    required this.app,
    required this.photos,
    required this.index,
  });
  final AppState app;
  final List photos;
  final int index;
  @override
  State<PhotoGallery> createState() => _PhotoGalleryState();
}

class _PhotoGalleryState extends State<PhotoGallery> {
  late final PageController controller;
  late int index;
  @override
  void initState() {
    super.initState();
    index = widget.index;
    controller = PageController(initialPage: index);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      title: Text('${index + 1} / ${widget.photos.length}'),
    ),
    body: PageView.builder(
      controller: controller,
      itemCount: widget.photos.length,
      onPageChanged: (i) => setState(() => index = i),
      itemBuilder: (context, i) => FutureBuilder(
        future: widget.app.native.thumbnail(widget.photos[i]['index'], 2048),
        builder: (context, s) => s.hasData
            ? Stack(
                children: [
                  Center(
                    child: InteractiveViewer(child: Image.memory(s.data!)),
                  ),
                  if (widget.photos[i]['video'] == true)
                    Center(
                      child: IconButton(
                        iconSize: 64,
                        onPressed: () => widget.app.native.playVideo(
                          widget.photos[i]['index'],
                        ),
                        icon: const Icon(Icons.play_circle_fill),
                      ),
                    ),
                ],
              )
            : Center(
                child: s.hasError
                    ? Text('${s.error}')
                    : const CircularProgressIndicator(),
              ),
      ),
    ),
  );
}

Future<void> showSettings(BuildContext context, AppState app) => panel(
  context,
  'Settings',
  Consumer(
    builder: (context, ref, _) {
      ref.watch(appProvider);
      final d = app.device;
      return ListView(
        children: [
          section('Your phone'),
          ListTile(
            title: const Text('Background location'),
            trailing: DropdownButton<int>(
              value: d['cadence'] ?? -1,
              items: const [
                DropdownMenuItem(value: -1, child: Text('Off')),
                DropdownMenuItem(value: 0, child: Text('Significant changes')),
                DropdownMenuItem(value: 60, child: Text('Every hour')),
                DropdownMenuItem(value: 30, child: Text('Every 30 minutes')),
                DropdownMenuItem(value: 15, child: Text('Every 15 minutes')),
                DropdownMenuItem(value: 5, child: Text('Every 5 minutes')),
                DropdownMenuItem(value: 1, child: Text('Every minute')),
              ],
              onChanged: (v) => configure(app, {'cadence': v}),
            ),
          ),
          ListTile(
            title: const Text('Location precision'),
            trailing: DropdownButton<int>(
              value: d['precision'] ?? 80,
              items: [30, 80, 200, 0]
                  .map(
                    (n) => DropdownMenuItem(
                      value: n,
                      child: Text(n == 0 ? 'Every fix' : 'Within $n m'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => configure(app, {'precision': v}),
            ),
          ),
          GlassSwitch(
            title: const Text('Apple Health workouts'),
            value: d['health'] == true,
            onChanged: (v) => configure(app, {'health': v}),
          ),
          GlassSwitch(
            title: const Text('Photo locations'),
            value: d['photos'] == true,
            onChanged: (v) => configure(app, {'photos': v}),
          ),
          fact('Queued locations', d['pending'] ?? 0),
          ListTile(
            title: const Text('Sync now'),
            leading: const Icon(Icons.sync),
            onTap: app.busy ? null : app.sync,
          ),
          if ('${d['error'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('${d['error']}'),
            ),
          section('Personal'),
          ListTile(
            title: const Text('Home'),
            subtitle: Text(
              '${app.prefs['home']?['name'] ?? 'Guess from your visits'}',
            ),
            leading: const Icon(Icons.home_outlined),
            onTap: () => chooseHome(context, app),
          ),
          ListTile(
            title: const Text('Device name'),
            subtitle: Text('${d['deviceName'] ?? 'iPhone'}'),
            onTap: () async {
              final name = await askText(
                context,
                'Device name',
                '${d['deviceName'] ?? 'iPhone'}',
              );
              if (name != null) await configure(app, {'deviceName': name});
            },
          ),
          fact('Server', app.api.server),
          ListTile(
            title: const Text('Clock'),
            trailing: DropdownButton<String>(
              value: '${app.prefs['clock'] ?? 'auto'}',
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('Automatic')),
                DropdownMenuItem(value: '12', child: Text('12-hour')),
                DropdownMenuItem(value: '24', child: Text('24-hour')),
              ],
              onChanged: (v) => app.run(() async {
                app.prefs['clock'] = v;
                await app.api.post('/api/prefs', {'prefs': app.prefs});
              }),
            ),
          ),
          if (app.user?['admin'] == true)
            ListTile(
              title: const Text('Backups'),
              leading: const Icon(Icons.backup_outlined),
              onTap: () => showBackup(context, app),
            ),
          ListTile(
            title: const Text('Sign out'),
            leading: const Icon(Icons.logout),
            onTap: () async {
              Navigator.pop(context);
              await app.signOut();
            },
          ),
          const ListTile(
            title: Text('Sporra Preview'),
            subtitle: Text('0.2.0 · Native map for iOS'),
          ),
        ],
      );
    },
  ),
);
Future<void> configure(AppState app, Map<String, dynamic> patch) =>
    app.run(() async {
      app.device = Map<String, dynamic>.from(
        jsonDecode(await app.native.configure(jsonEncode(patch))),
      );
      app.changed();
    });
Future<void> showBackup(BuildContext context, AppState app) => panel(
  context,
  'Backups',
  AsyncList(
    load: () => app.api.get('/api/backup'),
    builder: (context, data) => ListView(
      children: [
        ListTile(
          title: const Text('Back up now on the server'),
          leading: const Icon(Icons.backup),
          onTap: () => app.run(() async {
            await app.api.post('/api/backup/run', {});
          }),
        ),
        for (final backup in data['backup']['files'])
          ListTile(
            title: Text(date(backup['at'])),
            subtitle: Text(
              '${((backup['size'] as num) / 1024 / 1024).toStringAsFixed(1)} MB',
            ),
            leading: const Icon(Icons.download),
            onTap: () => app.run(() async {
              final name = '${backup['name']}';
              final bytes = await app.api.download(
                '/api/backup/download?name=${Uri.encodeQueryComponent(name)}',
              );
              final dir = await getTemporaryDirectory();
              final file = File('${dir.path}/$name');
              await file.writeAsBytes(bytes);
              await SharePlus.instance.share(
                ShareParams(
                  files: [XFile(file.path)],
                  sharePositionOrigin: context.mounted
                      ? ((context.findRenderObject() as RenderBox?)
                                    ?.localToGlobal(Offset.zero) ??
                                Offset.zero) &
                            const Size(1, 1)
                      : null,
                ),
              );
            }),
          ),
      ],
    ),
  ),
);

Future<void> showConnections(BuildContext context, AppState app) => panel(
  context,
  'Sync connections',
  AsyncList(
    load: () async => {
      'strava': await app.api.get('/api/strava'),
      'ha': await app.api.get('/api/ha'),
      'device': await app.api.get('/api/device'),
    },
    builder: (context, data) => ListView(
      children: [
        ListTile(
          title: const Text('Your phone'),
          subtitle: Text('${app.device['deviceName'] ?? 'iPhone'}'),
          leading: const Icon(Icons.phone_iphone),
          onTap: () => showSettings(context, app),
        ),
        ListTile(
          title: const Text('Strava'),
          onTap: () => setupStrava(context, app),
          subtitle: Text(
            data['strava']['link'] == null ? 'Not connected' : 'Connected',
          ),
          leading: const Icon(Icons.directions_bike),
          trailing: TextButton(
            onPressed: data['strava']['link'] == null
                ? null
                : () => app.run(() async {
                    await app.api.post('/api/strava/sync', {});
                    app.changed();
                  }),
            child: const Text('Sync'),
          ),
        ),
        ListTile(
          title: const Text('Home Assistant'),
          onTap: () => setupHomeAssistant(context, app),
          subtitle: Text(
            data['ha']['link'] == null ? 'Not connected' : 'Connected',
          ),
          leading: const Icon(Icons.home_outlined),
          trailing: TextButton(
            onPressed: data['ha']['link'] == null
                ? null
                : () => app.run(() async {
                    await app.api.post('/api/ha/sync', {});
                    app.changed();
                  }),
            child: const Text('Sync'),
          ),
        ),
      ],
    ),
  ),
);
Future<void> showAdmin(BuildContext context, AppState app) => panel(
  context,
  'Administration',
  AsyncList(
    load: () => app.api.get('/api/admin/users'),
    builder: (context, data) => ListView(
      children: [
        for (final u in data['users'] ?? [])
          ListTile(
            title: Text('${u['username']}'),
            subtitle: Text(u['admin'] == true ? 'Administrator' : 'Account'),
          ),
      ],
    ),
  ),
);

Future<void> showActivityDetails(
  BuildContext context,
  AppState app,
  Map<String, dynamic> route,
) => panel(
  context,
  '${route['name'] ?? 'Activity'}',
  Consumer(
    builder: (context, ref, _) {
      ref.watch(appProvider);
      return ListView(
        children: [
          fact('Activity', route['sport'] ?? 'Recorded route'),
          fact(
            'Distance',
            '${(((route['lengthM'] as num?)?.toDouble() ?? 0) / 1000).toStringAsFixed(2)} km',
          ),
          fact('Elevation gain', '${route['elevUp'] ?? 0} m'),
          fact('Started', date(route['firstAt'])),
          fact('Finished', date(route['lastAt'])),
          ListTile(
            title: Text(
              app.selectedRoute == route['id']
                  ? 'Show all activities'
                  : 'Show only this activity',
            ),
            leading: const Icon(Icons.route_outlined),
            onTap: () {
              app.selectedRoute = app.selectedRoute == route['id']
                  ? null
                  : route['id'];
              app.changed();
              Navigator.pop(context);
            },
          ),
          for (final field in {
            'name': 'Name',
            'sport': 'Activity type',
            'place': 'Place',
          }.entries)
            ListTile(
              title: Text('Edit ${field.value.toLowerCase()}'),
              leading: const Icon(Icons.edit_outlined),
              onTap: app.busy
                  ? null
                  : () async {
                      final text = await askText(
                        context,
                        field.value,
                        '${route[field.key] ?? ''}',
                      );
                      if (text != null &&
                          (field.key != 'name' || text.isNotEmpty)) {
                        await app.run(() async {
                          await app.api.post('/api/routes/update', {
                            'id': route['id'],
                            field.key: text,
                          });
                          route[field.key] = text;
                          app.changed();
                        });
                      }
                    },
            ),
          ListTile(
            title: const Text('Activity colour'),
            trailing: ColorDot(
              app.activityColor(
                '${route['sport'] ?? ''}'.isEmpty
                    ? '\u0000none'
                    : '${route['sport']}',
              ),
            ),
            onTap: () => showActivityStyle(context, app),
          ),
        ],
      );
    },
  ),
);

Future<void> showActivities(
  BuildContext context,
  AppState app,
  MapLibreMapController? map,
) => panel(
  context,
  'Activities',
  AsyncList(
    load: () => app.api.get('/api/render/activity-stats'),
    builder: (context, data) => ListView(
      children: [
        fact('Activities', (data['routes'] as List).length),
        fact('Total distance', data['distance']),
        if (data['duration'] != null) fact('Time recorded', data['duration']),
        if (data['longest'] != null)
          fact(
            'Longest',
            '${data['longest']['distance']} · ${data['longest']['name']}',
          ),
        if ((data['years'] as List).length > 1) ...[
          section('Distance by year'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: YearChart(
              entries: List<Map<String, dynamic>>.from(data['years']),
            ),
          ),
        ],
        section('Your activities'),
        for (final route in data['routes'])
          ListTile(
            title: Text('${route['name']}'),
            subtitle: Text('${route['sport']} · ${date(route['firstAt'])}'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () {
              if (map != null) goTo(map, route);
              showRoute(context, app, Map<String, dynamic>.from(route));
            },
          ),
        if ((data['routes'] as List).isEmpty)
          const ListTile(
            title: Text(
              'No activities yet. Import a file or connect a sync source.',
            ),
          ),
      ],
    ),
  ),
);
Future<void> showAirport(BuildContext context, Map<String, dynamic> airport) =>
    panel(
      context,
      '${airport['name'] ?? 'Airport'}',
      ListView(
        children: [
          for (final field in ['iata', 'icao', 'city', 'country', 'elevation'])
            if (airport[field] != null && '${airport[field]}'.isNotEmpty)
              fact(field.toUpperCase(), airport[field]),
        ],
      ),
    );
Future<String?> askText(
  BuildContext context,
  String title,
  String initial, {
  bool obscure = false,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: obscure,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // A dialog's closing animation can still read its controller.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return result;
}

Future<void> setupStrava(BuildContext context, AppState app) async {
  final id = await askText(context, 'Strava application client ID', '');
  if (id == null || !context.mounted) return;
  final secret = await askText(
    context,
    'Strava application client secret',
    '',
    obscure: true,
  );
  if (secret == null) return;
  await app.run(() async {
    await app.api.post('/api/strava', {
      'clientId': id,
      'clientSecret': secret,
      'saveRoutes': true,
      'enabled': true,
    });
    final authorization = await app.api.post('/api/strava/authorize', {
      'native': true,
    });
    final callback = Uri.parse(
      await app.native.authenticate(authorization['url']),
    );
    if (callback.queryParameters['strava'] != 'ok') {
      throw Exception('Strava authorization did not complete.');
    }
    await app.api.post('/api/strava/sync', {});
    app.changed();
  });
}

Future<void> setupHomeAssistant(BuildContext context, AppState app) async {
  final address = await askText(context, 'Home Assistant address', '');
  if (address == null || !context.mounted) return;
  final token = await askText(
    context,
    'Long-lived access token',
    '',
    obscure: true,
  );
  if (token == null) return;
  await app.run(() async {
    final result = await app.api.post('/api/ha/probe', {
      'baseUrl': address,
      'token': token,
    });
    if (!context.mounted) return;
    final selected = <String>{};
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Follow these devices'),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final entity in result['entities'])
                  GlassSwitch(
                    title: Text('${entity['name'] ?? entity['id']}'),
                    value: selected.contains(entity['id']),
                    onChanged: (on) => setState(() {
                      if (on == true) {
                        selected.add(entity['id']);
                      } else {
                        selected.remove(entity['id']);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    await app.api.post('/api/ha', {
      'baseUrl': address,
      'token': token,
      'entities': selected.toList(),
      'enabled': true,
    });
    await app.api.post('/api/ha/sync', {});
    app.changed();
  });
}

Future<void> chooseHome(BuildContext context, AppState app) async {
  final query = await askText(context, 'Find your home town', '');
  if (query == null) return;
  await app.run(() async {
    final result = await app.api.get(
      '/api/search?q=${Uri.encodeQueryComponent(query)}',
    );
    final places = (result['results'] as List)
        .where((p) => p['lng'] != null && p['lat'] != null)
        .toList();
    if (places.isEmpty) throw Exception('No town matched that name.');
    if (!context.mounted) return;
    final picked = await showDialog<Map>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Set home'),
        children: [
          for (final p in places)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p),
              child: Text('${p['name']}'),
            ),
        ],
      ),
    );
    if (picked != null) {
      await app.patchPrefs({
        'home': {
          'lng': picked['lng'],
          'lat': picked['lat'],
          'name': picked['name'],
        },
      });
    }
    app.changed();
  });
}

class ColorDot extends StatelessWidget {
  const ColorDot(this.hex, {super.key});
  final String hex;
  @override
  Widget build(BuildContext context) => Container(
    width: 28,
    height: 28,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: parseColor(hex),
      border: Border.all(color: Colors.white38, width: 2),
    ),
  );
}

Future<String?> chooseColor(BuildContext context, String initial) async {
  final text = TextEditingController(text: initial.substring(0, 7));
  double opacity = initial.length == 9
      ? int.parse(initial.substring(7), radix: 16) / 255
      : 1;
  String value = initial.substring(0, 7);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, set) => AlertDialog(
        title: const Text('Colour'),
        content: SizedBox(
          width: 280,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    for (final hex in [
                      '#60acff',
                      '#ff9147',
                      '#ff7ab8',
                      '#5fd0a8',
                      '#ffcf5c',
                      '#b98cff',
                      '#df4949',
                      '#ffffff',
                    ])
                      InkWell(
                        onTap: () => set(() {
                          value = hex;
                          text.text = hex;
                        }),
                        child: ColorDot(hex),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: text,
                  decoration: InputDecoration(
                    labelText: 'Hex colour',
                    errorText: RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text.text)
                        ? null
                        : 'Use #RRGGBB',
                  ),
                  onChanged: (v) => set(() {
                    if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v)) value = v;
                  }),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    ColorDot(value),
                    const Spacer(),
                    Text('Opacity ${(opacity * 100).round()}%'),
                  ],
                ),
                Slider(
                  value: opacity,
                  onChanged: (v) => set(() => opacity = v),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text.text)
                ? () => Navigator.pop(
                    context,
                    '$value${(opacity * 255).round().toRadixString(16).padLeft(2, '0')}',
                  )
                : null,
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  text.dispose();
  return result;
}

Future<void> showActivityStyle(BuildContext context, AppState app) => panel(
  context,
  'Activities',
  AsyncList(
    load: () => app.api.get('/api/routes'),
    builder: (context, data) => Consumer(
      builder: (context, ref, _) {
        final a = ref.watch(appProvider);
        final sports =
            (data['routes'] as List)
                .map(
                  (r) => '${r['sport'] ?? ''}'.isEmpty
                      ? '\u0000none'
                      : '${r['sport']}',
                )
                .toSet()
                .toList()
              ..sort();
        return ListView(
          children: [
            GlassSwitch(
              title: const Text('Color each route'),
              subtitle: const Text('Give every activity line its own colour'),
              value: a.routeView['rainbow'] == true,
              onChanged: a.busy
                  ? null
                  : (v) => a.run(() => a.saveRouteView({'rainbow': v})),
            ),
            for (final sport in sports)
              ListTile(
                title: Text(sport == '\u0000none' ? 'Other activities' : sport),
                leading: IconButton(
                  tooltip: a.activityVisible(sport)
                      ? 'Hide activity'
                      : 'Show activity',
                  icon: Icon(
                    a.activityVisible(sport)
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: a.busy
                      ? null
                      : () => a.run(() async {
                          final hidden = Set<String>.from(
                            a.routeView['hidden'] ?? [],
                          );
                          if (!hidden.remove(sport)) hidden.add(sport);
                          await a.saveRouteView({'hidden': hidden.toList()});
                        }),
                ),
                trailing: ColorDot(a.activityColor(sport)),
                onTap: a.busy
                    ? null
                    : () async {
                        final color = await chooseColor(
                          context,
                          a.activityColor(sport),
                        );
                        if (color != null) {
                          await a.run(
                            () => a.saveRouteView({
                              'colors': {
                                ...?a.routeView['colors'] as Map?,
                                sport: color,
                              },
                            }),
                          );
                        }
                      },
              ),
            if (sports.isEmpty)
              const ListTile(
                title: Text(
                  'Import or sync activities to customize their colours.',
                ),
              ),
            ListTile(
              title: const Text('Reset activity appearance'),
              leading: const Icon(Icons.restart_alt),
              onTap: a.busy
                  ? null
                  : () => a.run(
                      () => a.saveRouteView({
                        'colors': {},
                        'hidden': [],
                        'rainbow': false,
                      }),
                    ),
            ),
          ],
        );
      },
    ),
  ),
);

Future<void> showRoute(
  BuildContext context,
  AppState app,
  Map<String, dynamic> route,
) async {
  Navigator.of(context).popUntil((r) => r.isFirst);
  await app.openActivity(route['id']);
}
