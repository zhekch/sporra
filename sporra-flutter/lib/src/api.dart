import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class SporraApi {
  SporraApi({http.Client? client})
    : client =
          client ??
          (Platform.isIOS
              ? CupertinoClient.defaultSessionConfiguration()
              : http.Client());
  final http.Client client;
  String server = '';
  static const isolateThreshold = 64 * 1024;
  static const cacheLimit = 128;
  static const cacheBytes = 8 * 1024 * 1024;
  static const dataFreshness = Duration(seconds: 60);
  static const viewportFreshness = Duration(seconds: 15);
  static const referenceFreshness = Duration(days: 1);
  static const offlineRetention = Duration(days: 1);
  final _cache = <String, ({String? tag, String json, DateTime at})>{};
  final _pending = <String, Future<dynamic>>{};
  int _epoch = 0;
  File? _file;
  String? _scope;
  Timer? _saveTimer;
  Future<void> _diskWork = Future.value();
  Uri uri(String path) => Uri.parse(server).resolve(path);

  Duration? _freshness(Uri url) {
    if (url.path == '/api/render/style' ||
        url.path == '/api/render/reference') {
      return referenceFreshness;
    }
    if (url.path == '/api/render/cells' ||
        url.path == '/api/render/regions' ||
        url.path == '/api/render/at' ||
        url.path == '/api/search') {
      return viewportFreshness;
    }
    return const {
          '/api/routes',
          '/api/days',
          '/api/trips',
          '/api/stats',
          '/api/sources',
          '/api/prefs',
          '/api/render/routes',
          '/api/render/track',
          '/api/render/activity',
          '/api/render/activity-stats',
        }.contains(url.path)
        ? dataFreshness
        : null;
  }

  // Restore only after the server has identified the current cookie session.
  Future<void> restore(File file, String account) async {
    final epoch = _epoch;
    final scope = '$server\n$account';
    _file = file;
    _scope = scope;
    try {
      await _diskWork;
      final saved = await decodeJson(await file.readAsString()) as Map;
      if (_epoch != epoch || saved['scope'] != scope) return;
      for (final row in (saved['entries'] as List).take(cacheLimit)) {
        final url = Uri.parse(row['url'] as String);
        final at = DateTime.fromMillisecondsSinceEpoch(row['at'] as int);
        if (url.origin != uri('/').origin ||
            _freshness(url) == null ||
            DateTime.now().difference(at) > offlineRetention) {
          continue;
        }
        final json = row['json'] as String;
        _cache[url.toString()] = (
          tag: row['tag'] as String?,
          json: json,
          at: at,
        );
      }
      _trim();
    } catch (_) {
      // Device caches are disposable; a missing or damaged file cannot block login.
    }
  }

  void _trim() {
    var size = _cache.values.fold(0, (n, entry) => n + entry.json.length * 2);
    while (_cache.length > cacheLimit || size > cacheBytes) {
      size -= _cache.remove(_cache.keys.first)!.json.length * 2;
    }
  }

  void _save() {
    _saveTimer?.cancel();
    if (_file == null) return;
    _saveTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(flushCache()),
    );
  }

  Future<void> flushCache() {
    _saveTimer?.cancel();
    final file = _file;
    if (file == null) return _diskWork;
    final snapshot = {
      'scope': _scope,
      'entries': [
        for (final entry in _cache.entries)
          {
            'url': entry.key,
            'tag': entry.value.tag,
            'json': entry.value.json,
            'at': entry.value.at.millisecondsSinceEpoch,
          },
      ],
    };
    return _diskWork = _diskWork.then((_) async {
      try {
        final json = await compute(jsonEncode, snapshot);
        await file.parent.create(recursive: true);
        await file.writeAsString(json, flush: true);
      } catch (_) {}
    });
  }

  void clear() {
    _epoch++;
    _cache.clear();
    _pending.clear();
    _saveTimer?.cancel();
    final file = _file;
    if (file != null) {
      _diskWork = _diskWork.then((_) async {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      });
    }
  }

  Future<dynamic> get(String path, {bool refresh = false}) async {
    final url = uri(path);
    final key = url.toString();
    final cached = _cache[key];
    final freshness = _freshness(url);
    if (!refresh &&
        cached != null &&
        freshness != null &&
        DateTime.now().difference(cached.at) < freshness) {
      // Callers filter and decorate GeoJSON; never lend them the cached object.
      _cache.remove(key);
      _cache[key] = cached;
      return decodeJson(cached.json);
    }
    final epoch = _epoch;
    final work = _pending[key] ??= _read(url, cached, epoch);
    try {
      return await decodeJson(await work as String);
    } finally {
      if (identical(_pending[key], work)) _pending.remove(key);
    }
  }

  Future<String> _read(
    Uri url,
    ({String? tag, String json, DateTime at})? cached,
    int epoch,
  ) async {
    http.Response response;
    try {
      response = await client
          .get(
            url,
            headers: {
              'X-Sporra-Client': 'ios-flutter',
              if (cached?.tag != null) 'If-None-Match': cached!.tag!,
            },
          )
          .timeout(const Duration(seconds: 40));
    } on Exception catch (error) {
      if ((error is SocketException ||
              error is http.ClientException ||
              error is TimeoutException) &&
          cached != null &&
          epoch == _epoch &&
          DateTime.now().difference(cached.at) < offlineRetention) {
        return cached.json;
      }
      rethrow;
    }
    if (response.statusCode != 304 &&
        (response.statusCode < 200 || response.statusCode >= 300)) {
      if (response.statusCode == 401) clear();
      _decode(response);
    }
    final json = response.statusCode == 304 && cached != null
        ? cached.json
        : response.body;
    if (epoch == _epoch && _freshness(url) != null) {
      _cache.remove(url.toString());
      _cache[url.toString()] = (
        tag:
            response.headers['etag'] ??
            (response.statusCode == 304 ? cached?.tag : null),
        json: json,
        at: DateTime.now(),
      );
      _trim();
      _save();
    }
    return json;
  }

  static Future<dynamic> decodeJson(String json) async =>
      json.length >= isolateThreshold
      ? compute(jsonDecode, json)
      : jsonDecode(json);

  int get revision => _epoch;

  Future<Map<String, dynamic>> getMany(Map<String, String> paths) async {
    final entries = paths.entries.toList();
    final values = await Future.wait(entries.map((entry) => get(entry.value)));
    return {for (var i = 0; i < entries.length; i++) entries[i].key: values[i]};
  }

  Future<dynamic> post(String path, Map<String, dynamic> value) async {
    clear();
    final response = await client
        .post(
          uri(path),
          headers: {
            'Content-Type': 'application/json',
            'X-Sporra-Client': 'ios-flutter',
          },
          body: jsonEncode(value),
        )
        .timeout(const Duration(minutes: 2));
    final result = _decode(response);
    clear();
    return result;
  }

  dynamic _decode(http.Response response) {
    dynamic body;
    try {
      body = jsonDecode(response.body);
    } catch (_) {
      body = {};
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        body is Map
            ? '${body['error'] ?? 'Server answered ${response.statusCode}'}'
            : 'Invalid server response',
      );
    }
    return body;
  }

  Future<Uint8List> download(String path) async {
    final response = await client.get(uri(path));
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, 'Download failed');
    }
    return response.bodyBytes;
  }
}
