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
  bool photos = false;
  bool rail = false;
  bool trails = false;
  bool airports = false;
  final hidden = <String>{};
  int revision = 0;
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

  Future<void> saveAppearance() async {
    await patchPrefs({
      'accent': accent,
      'accents': {...?prefs['accents'] as Map?, 'dark': accent},
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
    revision++;
  });
  Future<void> signOut() => run(() async {
    try {
      await api.post('/api/logout', {});
    } finally {
      await native.signOut();
      api.clear();
      prefs = {};
      user = null;
      undo = null;
      revision++;
    }
  });
}
