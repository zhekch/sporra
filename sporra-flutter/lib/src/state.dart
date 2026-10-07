import 'mapbox.dart' as mb;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'map_preferences.dart';
import 'native.g.dart';

final appProvider = ChangeNotifierProvider((ref) => AppState());

class AppState extends ChangeNotifier {
  AppState({SporraApi? api}) : api = api ?? SporraApi() {
    this.api.onMapDataChanged = changed;
  }
  final SporraApi api;
  final mapPreferences = MapPreferences();
  final native = SporraNative();
  Map<String, dynamic> device = {};
  Map<String, dynamic> prefs = {};
  Map<String, dynamic>? user;
  bool ready = false;
  bool busy = false;
  String? error;
  String style = 'dark';
  String mode = 'flat';
  String detail = 'auto';
  String accent = '#60acff';
  bool routes = true;
  bool menuOpen = false;
  void setMenuOpen(bool value) {
    menuOpen = value;
    notifyListeners();
  }

  bool photos = false;
  static const thumbnailBytes = 24 * 1024 * 1024;
  static const thumbnailLimit = 64;
  List<dynamic>? photoItems;
  Future<List<dynamic>>? _photoRead;
  final _thumbnails = <(int, int), Uint8List>{};
  final _thumbnailReads = <(int, int), Future<Uint8List>>{};
  int _photoGeneration = 0;

  Future<Uint8List> thumbnail(int index, int pixels) async {
    final key = (index, pixels);
    final cached = _thumbnails.remove(key);
    if (cached != null) {
      _thumbnails[key] = cached;
      return cached;
    }
    final generation = _photoGeneration;
    final read = _thumbnailReads[key] ??= native.thumbnail(index, pixels);
    try {
      final bytes = await read;
      if (generation == _photoGeneration) {
        _thumbnails[key] = bytes;
        var size = _thumbnails.values.fold(0, (n, value) => n + value.length);
        while (_thumbnails.length > thumbnailLimit || size > thumbnailBytes) {
          size -= _thumbnails.remove(_thumbnails.keys.first)!.length;
        }
      }
      return bytes;
    } finally {
      if (identical(_thumbnailReads[key], read)) _thumbnailReads.remove(key);
    }
  }

  void clearPhotos() {
    _photoGeneration++;
    photoItems = null;
    _photoRead = null;
    _thumbnails.clear();
    _thumbnailReads.clear();
  }

  Future<List<dynamic>> readPhotos() async {
    if (photoItems != null) return photoItems!;
    final generation = _photoGeneration;
    final read = _photoRead ??= native.photos().then(
      (json) async => await SporraApi.decodeJson(json) as List,
    );
    try {
      final items = await read;
      if (generation == _photoGeneration) photoItems = items;
      return items;
    } finally {
      if (identical(_photoRead, read)) _photoRead = null;
    }
  }

  List<dynamic> photosInTrack(List<dynamic> items) {
    final from = track?['from'], to = track?['to'];
    if (from == null || to == null) return items;
    return items
        .where((p) => p['time'] is num && p['time'] >= from && p['time'] < to)
        .toList();
  }

  bool get railTechnical => prefs['railTechnical'] == true;
  bool railGroupOn(String key) =>
      (prefs['railGroups'] as Map?)?[key] as bool? ??
      !['linenumbers', 'symbols', 'milestones'].contains(key);
  bool rail = false;
  bool trails = false;
  String trailTheme = 'hiking';
  double trailStrength = 0.75;
  bool airports = false;
  final airportGroups = <String>{'airline'};
  bool ground = true;

  Future<void> randomActivityColors(List<String> sports) async {
    final result = await api.post('/api/render/activity-palette', {
      'keys': sports,
    });
    await saveRouteView({
      'colors': {...?routeView['colors'] as Map?, ...result['colors'] as Map},
      'rainbow': false,
    });
  }

  Future<void> clearDeviceCache() async {
    api.clear();
    clearPhotos();
    changed();
    await api.flushCache();
  }

  final hidden = <String>{};
  int revision = 0;
  bool cellInfo = true;
  bool clearingRegion = false;
  dynamic selectedRoute;
  List<dynamic> stackIds = [];
  Map<String, dynamic>? activity;
  String? activityMetric;
  int? activitySample;
  int activityRequest = 0;
  Future<void> openActivity(dynamic id, {bool keepMetric = false}) {
    final request = ++activityRequest;
    return run(() async {
      final data = Map<String, dynamic>.from(
        await api.get('/api/render/activity?id=$id'),
      );
      if (request != activityRequest) return;
      final graphs = data['graphs'] as Map;
      activityMetric = keepMetric && graphs[activityMetric] != null
          ? activityMetric
          : graphs['speed'] != null
          ? 'speed'
          : graphs['elev'] != null
          ? 'elev'
          : null;
      activity = data;
      activitySample = null;
      selectedRoute = id;
      changed();
    });
  }

  void closeActivity() {
    activityRequest++;
    activity = null;
    activitySample = null;
    activityMetric = null;
    selectedRoute = null;
    changed();
  }

  void scrubActivity(int index) {
    if (activitySample == index) return;
    activitySample = index;
    notifyListeners();
  }

  Future<void> stepActivity(int delta) async {
    final routes = List<Map<String, dynamic>>.from(
      (await api.get('/api/routes?fold=1'))['routes'],
    );
    routes.sort((a, b) => (a['firstAt'] as num).compareTo(b['firstAt'] as num));
    final index = routes.indexWhere((r) => r['id'] == activity?['route']['id']);
    final next = index + delta;
    if (index >= 0 && next >= 0 && next < routes.length) {
      await openActivity(routes[next]['id'], keepMetric: true);
    }
  }

  Map<String, dynamic>? track;
  String? trackDay;
  int trackRequest = 0;
  List<String> recordedDays = [];
  bool canStepDay(int delta) {
    final i = recordedDays.indexOf(trackDay ?? '');
    return i >= 0 && i + delta >= 0 && i + delta < recordedDays.length;
  }

  Future<void> selectTrack({dynamic trip, String? day}) async {
    final request = ++trackRequest;
    await run(() async {
      final query = Uri(
        queryParameters: day != null ? {'day': day} : {'trip': '$trip'},
      ).query;
      final results = await Future.wait([
        api.get('/api/render/track?$query'),
        api.get('/api/days'),
      ]);
      final data = Map<String, dynamic>.from(results[0]);
      if (request != trackRequest) return;
      activityRequest++;
      activity = null;
      activityMetric = null;
      activitySample = null;
      selectedRoute = null;
      recordedDays =
          (results[1]['days'] as Map).keys.map((key) => '$key').toList()
            ..sort();
      if (request != trackRequest) return;
      if (trip != null) {
        data['label'] = (prefs['tripNames'] as Map?)?['$trip'] ?? data['label'];
      }
      track = data;
      trackDay = day;
      changed();
    });
  }

  void clearTrack() {
    trackRequest++;
    track = null;
    trackDay = null;
    changed();
  }

  Future<void> stepTrack(int delta) async {
    if (trackDay != null) return stepDay(delta);
    if (track == null) return;
    final trips = List<Map<String, dynamic>>.from(
      (await api.get('/api/trips'))['trips'],
    );
    final hiddenTrips = List<String>.from(prefs['hiddenTrips'] ?? []);
    trips.removeWhere((trip) => hiddenTrips.contains('${trip['id']}'));
    trips.sort((a, b) => (a['start'] as num).compareTo(b['start'] as num));
    final index = trips.indexWhere((trip) => trip['id'] == track!['id']);
    final next = index + delta;
    if (index >= 0 && next >= 0 && next < trips.length) {
      await selectTrack(trip: trips[next]['id']);
    }
  }

  Future<void> stepDay(int delta) async {
    if (trackDay == null) return;
    final days = recordedDays;
    final index = days.indexOf(trackDay!);
    final next = index + delta;
    if (index >= 0 && next >= 0 && next < days.length) {
      await selectTrack(day: days[next]);
    }
  }

  bool editing = false;
  String brushAction = 'paint';
  int brushSize = 1;
  Map<String, dynamic>? undo;

  Future<void> initialize() async {
    try {
      device = Map<String, dynamic>.from(jsonDecode(await native.settings()));
      final server = '${device['server'] ?? ''}';
      if (server.isNotEmpty) {
        api.server = server.contains('://') ? server : 'https://$server';
        final me = await api.get('/api/me');
        user = me['username'] == null ? null : Map<String, dynamic>.from(me);
        if (user != null) {
          await restoreCache();
          await loadPrefs();
          warmData();
        }
      }
    } catch (e) {
      error = '$e';
    }
    ready = true;
    notifyListeners();
  }

  Future<void> login(
    String address,
    String username,
    String password, {
    bool register = false,
  }) async {
    await run(() async {
      final url = Uri.tryParse(
        address.contains('://') ? address.trim() : 'https://${address.trim()}',
      );
      if (url == null ||
          url.host.isEmpty ||
          !['https', 'http'].contains(url.scheme)) {
        throw Exception('Enter a valid server address.');
      }
      api.server = url.toString();
      final health = await api.get('/api/health');
      if (health['app'] != 'sporra') {
        throw Exception(
          'This address answered, but it is not a Sporra server.',
        );
      }
      device = Map<String, dynamic>.from(
        jsonDecode(await native.configure(jsonEncode({'server': api.server}))),
      );
      final result = await api.post(register ? '/api/register' : '/api/login', {
        'username': username.trim(),
        'password': password,
      });
      user = Map<String, dynamic>.from(result);
      await restoreCache();
      await loadPrefs();
      warmData();
      revision++;
    });
  }

  Future<void> restoreCache() async {
    try {
      final directory = await getApplicationSupportDirectory();
      await mapPreferences.restore(
        File('${directory.path}/map-preferences.json'),
        '${api.server}\n${user!["username"]}',
      );
      await api.restore(
        File('${directory.path}/responses.json'),
        '${user!['username']}',
      );
    } catch (_) {
      // Memory caching still works when device storage is unavailable.
    }
  }

  void warmData() {
    for (final path in ['/api/days', '/api/trips', '/api/routes?fold=1']) {
      unawaited(api.get(path).then<void>((_) {}, onError: (Object _) {}));
    }
  }

  Future<void> loadPrefs() async {
    prefs = Map<String, dynamic>.from(
      (await api.get('/api/prefs'))['prefs'] ?? {},
    );
    accent =
        '${(prefs['accents'] as Map?)?['dark'] ?? prefs['accent'] ?? '#60acff'}';
    style = mb.effectiveBasemap(mapPreferences.style, mapboxToken);
    refreshSun();
    setStyle(style);
    mode = '${prefs['heatMode'] ?? 'flat'}';
    if (!['flat', 'visits', 'oldest', 'type'].contains(mode)) mode = 'flat';
  }

  String get mapboxToken => '${prefs['mapboxToken'] ?? ''}'.trim();
  bool get hasMapbox => mb.tokenComplaint(mapboxToken) == null;
  bool get isMapbox => mb.usesMapbox(style, mapboxToken);
  String get mapboxLight => switch (prefs['mapboxLight']) {
    'day' || 'dawn' => 'day',
    'night' || 'dusk' => 'night',
    _ => 'auto',
  };
  String lightPreset = mb.sunPhase(DateTime.now());
  double? sunLatitude, sunLongitude;
  void refreshSun({double? latitude, double? longitude}) {
    sunLatitude = latitude ?? sunLatitude;
    sunLongitude = longitude ?? sunLongitude;
    final next = mapboxLight == 'auto'
        ? mb.sunPhase(
            DateTime.now(),
            latitude: sunLatitude,
            longitude: sunLongitude,
          )
        : mapboxLight;
    if (next == lightPreset) return;
    lightPreset = next;
    setStyle(style);
  }

  Future<void> setMapboxLight(String value) async {
    await patchPrefs({'mapboxLight': value});
    refreshSun();
    changed();
  }

  Future<void> setMapboxToken(String value) async {
    final token = value.trim();
    if (token.isNotEmpty) await mb.checkMapboxToken(token);
    await patchPrefs({'mapboxToken': token});
    setStyle(token.isEmpty ? mb.effectiveBasemap(style, token) : 'mapbox');
  }

  String get accentTheme =>
      style == 'voyager' || (isMapbox && ['day', 'dawn'].contains(lightPreset))
      ? 'light'
      : 'dark';
  Map<String, dynamic> get routeView =>
      Map<String, dynamic>.from(prefs['routeView'] ?? {});
  String activityColor(String sport) =>
      '${(routeView['colors'] as Map?)?[sport] ?? '#ff9147'}';
  bool activityVisible(String sport) =>
      !(routeView['hidden'] as List? ?? []).contains(sport);
  Future<void> saveRouteView(Map<String, dynamic> patch) async {
    await patchPrefs({
      'routeView': {...routeView, ...patch},
    });
    changed();
  }

  void setStyle(String value) {
    style = mb.effectiveBasemap(value, mapboxToken);
    mapPreferences.style = style;
    mapPreferences.save();
    accent =
        '${(prefs['accents'] as Map?)?[accentTheme] ?? prefs['accent'] ?? '#60acff'}';
    changed();
  }

  void rememberPerspective(double tilt, double bearing) {
    mapPreferences.tilt = tilt;
    mapPreferences.bearing = bearing;
    mapPreferences.save();
  }

  Future<void> saveAppearance() async {
    await patchPrefs({
      'accent': accentTheme == 'dark' ? accent : prefs['accent'] ?? '#60acff',
      'accents': {...?prefs['accents'] as Map?, accentTheme: accent},
      'heatMode': mode,
    });
  }

  Future<void> patchPrefs(Map<String, dynamic> patch) async {
    final current = Map<String, dynamic>.from(
      (await api.get('/api/prefs'))['prefs'] ?? {},
    );
    prefs = {
      ...current,
      ...patch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    await api.post('/api/prefs', {'prefs': prefs});
  }

  String mapDataPath(int level, {bool fine = false}) =>
      '/api/render/${level < 6 ? 'cells' : 'regions'}?${renderQuery(level)}&info=1&fine=${fine && level >= 6 && level < 8 ? 1 : 0}';

  void warmMap(int level) {
    final levels = List.generate(9, (i) => i)
      ..sort((a, b) => (a - level).abs().compareTo((b - level).abs()));
    api.prefetch([
      for (final next in levels)
        if (next != level) mapDataPath(next),
      mapDataPath(6, fine: true),
      mapDataPath(7, fine: true),
    ]);
  }

  String renderQuery(int level, {String? bbox}) => Uri(
    queryParameters: {
      'level': '$level',
      'mode': mode,
      'accent': accent,
      'bbox': ?bbox,
      if (hidden.isNotEmpty) 'hidden': hidden.toList(),
    },
  ).query;
  void changed() {
    revision++;
    notifyListeners();
  }

  Future<void> run(Future<void> Function() work) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await work();
    } catch (e) {
      error = '$e';
      if (e is ApiException && e.status == 401) user = null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> sync() => run(() async {
    device = Map<String, dynamic>.from(jsonDecode(await native.sync()));
    if ('${device['error'] ?? ''}'.isNotEmpty) throw Exception(device['error']);
    clearPhotos();
    api.clear();
    warmData();
    revision++;
  });
  Future<void> signOut() => run(() async {
    try {
      await api.post('/api/logout', {});
    } finally {
      await clearSession();
    }
  });
  Future<void> clearSession() async {
    await native.signOut();
    api.clear();
    prefs = {};
    user = null;
    undo = null;
    hidden.clear();
    clearPhotos();
    recordedDays = [];
    activityRequest++;
    activity = null;
    activityMetric = null;
    activitySample = null;
    selectedRoute = null;
    stackIds = [];
    trackRequest++;
    track = null;
    trackDay = null;
    editing = false;
    clearingRegion = false;
    revision++;
    notifyListeners();
  }
}
