import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'api.dart';
import 'native.g.dart';

final appProvider = ChangeNotifierProvider((ref) => AppState());

class AppState extends ChangeNotifier {
  final api = SporraApi();
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
  List<dynamic>? photoItems;
  Future<List<dynamic>> readPhotos() async =>
      photoItems ??= jsonDecode(await native.photos()) as List;
  List<dynamic> photosInTrack(List<dynamic> items) {
    final from = track?['from'], to = track?['to'];
    if (from == null || to == null) return items;
    return items
        .where((p) => p['time'] is num && p['time'] >= from && p['time'] < to)
        .toList();
  }

  bool rail = false;
  bool trails = false;
  String trailTheme = 'hiking';
  double trailStrength = 0.75;
  bool airports = false;
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
      if (selectedRoute != null) selectedRoute = id;
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
    activitySample = index;
    notifyListeners();
  }

  Future<void> stepActivity(int delta) async {
    final routes = List<Map<String, dynamic>>.from(
      (await api.get('/api/routes'))['routes'],
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
      final data = Map<String, dynamic>.from(
        await api.get('/api/render/track?$query'),
      );
      if (request != trackRequest) return;
      activityRequest++;
      activity = null;
      activityMetric = null;
      activitySample = null;
      selectedRoute = null;
      recordedDays =
          ((await api.get('/api/days'))['days'] as Map).keys
              .map((key) => '$key')
              .toList()
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

  Future<void> stepDay(int delta) async {
    if (trackDay == null) return;
    final days =
        ((await api.get('/api/days'))['days'] as Map).keys
            .map((key) => '$key')
            .toList()
          ..sort();
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
        if (user != null) await loadPrefs();
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
      await loadPrefs();
      revision++;
    });
  }

  Future<void> loadPrefs() async {
    prefs = Map<String, dynamic>.from(
      (await api.get('/api/prefs'))['prefs'] ?? {},
    );
    accent =
        '${(prefs['accents'] as Map?)?['dark'] ?? prefs['accent'] ?? '#60acff'}';
    mode = '${prefs['heatMode'] ?? 'flat'}';
    if (!['flat', 'visits', 'oldest', 'type'].contains(mode)) mode = 'flat';
  }

  String get accentTheme => style == 'voyager' ? 'light' : 'dark';
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
    style = value;
    accent =
        '${(prefs['accents'] as Map?)?[accentTheme] ?? prefs['accent'] ?? '#60acff'}';
    changed();
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
    photoItems = null;
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
    photoItems = null;
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
