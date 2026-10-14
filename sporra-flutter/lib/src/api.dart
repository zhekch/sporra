import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cell_snapshot.dart';
import 'performance.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

bool isConnectionFailure(Object error) =>
    error is SocketException ||
    error is http.ClientException ||
    error is TimeoutException ||
    (error is ApiException && error.status >= 500);

String readableError(String message) =>
    RegExp(
      r'SocketException|ClientException|TimeoutException|Connection (?:reset|refused)|network.*(?:lost|connection)',
      caseSensitive: false,
    ).hasMatch(message)
    ? 'Unable to reach your server. Check your connection and retry.'
    : message;

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
  static const cacheLimit = 512;
  static const cacheBytes = 128 * 1024 * 1024;
  static const prefetchPreparedSnapshots = cellSnapshotLimit - 1;
  static const dataFreshness = Duration(seconds: 60);
  void Function()? onMapDataChanged;
  final _updates = StreamController<Uri>.broadcast();
  Stream<Uri> get updates => _updates.stream;
  final _cells = CellSnapshotReader();
  final _pathEpochs = <String, int>{};
  final _contentRevisions = <String, int>{};
  Timer? _prefetchTimer;
  int _prefetchGeneration = 0;
  final _cache = <String, ({String? tag, String json, DateTime at})>{};
  final _pending = <String, Future<String>>{};
  int _epoch = 0;
  int _revision = 0;
  int _cacheVersion = 0;
  int _queuedSaveVersion = 0;
  File? _file;
  String? _scope;
  Timer? _saveTimer;
  Future<void> _diskWork = Future.value();
  Uri uri(String path) => Uri.parse(server).resolve(path);

  bool _isMap(Uri url) =>
      url.path == '/api/render/cells' || url.path == '/api/render/regions';

  bool _cacheable(Uri url) =>
      _isMap(url) ||
      const {
        '/api/render/style',
        '/api/render/reference',
        '/api/render/at',
        '/api/search',
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
      }.contains(url.path);

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
        if (url.origin != uri('/').origin || !_cacheable(url)) {
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
    if (file == null || _queuedSaveVersion == _cacheVersion) return _diskWork;
    _queuedSaveVersion = _cacheVersion;
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
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(json, flush: true);
        await temporary.rename(file.path);
      } catch (_) {}
    });
  }

  void clear() {
    _epoch++;
    _revision++;
    _cacheVersion++;
    _pathEpochs.clear();
    _contentRevisions.clear();
    _cells.clear();
    cancelPrefetch();
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

  void _invalidatePaths(Set<String> paths, {bool retainContent = false}) {
    _revision++;
    _cacheVersion++;
    cancelPrefetch();
    for (final path in paths) {
      _pathEpochs[path] = (_pathEpochs[path] ?? 0) + 1;
    }
    bool affected(String key) => paths.contains(Uri.parse(key).path);
    _cache.removeWhere(
      (key, _) =>
          affected(key) &&
          (!retainContent || Uri.parse(key).path == '/api/prefs'),
    );
    _pending.removeWhere((key, _) => affected(key));
    _save();
  }

  Object revisionFor(String path) {
    final url = uri(path);
    return (
      _epoch,
      _pathEpochs[url.path] ?? 0,
      _contentRevisions[url.hasQuery ? url.toString() : url.path] ?? 0,
    );
  }

  Future<dynamic> get(
    String path, {
    bool refresh = false,
    bool revalidate = true,
  }) async => decodeJson(
    await _getJson(path, refresh: refresh, revalidate: revalidate),
  );

  Future<Map<String, dynamic>> getCells(
    String path,
    List<double> bounds, {
    bool revalidate = true,
  }) async {
    final clock = Stopwatch()..start();
    final epoch = _epoch;
    final json = await _getJson(path, revalidate: revalidate);
    final data = await _cells.read('$epoch\n${uri(path)}', json, bounds);
    tracePerformance('cells-read', clock, {
      'cells': (data['rows'] as List).length,
    });
    return data;
  }

  bool hasCached(String path) => _cache.containsKey(uri(path).toString());

  Future<void> prepareCells(String path) async {
    final cached = _cache[uri(path).toString()];
    if (cached != null) {
      await _cells.read('$_epoch\n${uri(path)}', cached.json, null);
    }
  }

  // Validation shares the foreground request and never decodes a second full
  // snapshot on the UI isolate. Changed responses notify their visible owners.
  void revalidate(String path) => unawaited(
    _getJson(path, refresh: true).then<void>((_) {}, onError: (Object _) {}),
  );

  Future<String> _getJson(
    String path, {
    bool refresh = false,
    bool revalidate = true,
  }) async {
    final url = uri(path);
    final key = url.toString();
    final cached = _cache[key];
    if (_cacheable(url)) {
      tracePerformance('cache ${url.path}', Stopwatch(), {
        'hit': cached == null ? 0 : 1,
      });
    }
    if (!refresh && cached != null && _cacheable(url)) {
      if (revalidate) this.revalidate(path);
      // Callers filter and decorate GeoJSON; never lend them the cached object.
      _cache.remove(key);
      _cache[key] = cached;
      return cached.json;
    }
    final epoch = _epoch;
    final work = _pending[key] ??= _read(
      url,
      cached,
      epoch,
      _pathEpochs[url.path] ?? 0,
    );
    try {
      return await work;
    } finally {
      if (identical(_pending[key], work)) _pending.remove(key);
    }
  }

  Future<String> _read(
    Uri url,
    ({String? tag, String json, DateTime at})? cached,
    int epoch,
    int pathEpoch,
  ) async {
    http.Response response;
    final clock = Stopwatch()..start();
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
          pathEpoch == (_pathEpochs[url.path] ?? 0)) {
        return cached.json;
      }
      rethrow;
    }
    final endpoint = _cacheable(url) || url.path == '/api/me'
        ? url.path
        : 'other';
    tracePerformance('http $endpoint', clock, {'status': response.statusCode});
    if (response.statusCode != 304 &&
        (response.statusCode < 200 || response.statusCode >= 300)) {
      if (response.statusCode == 401) clear();
      _decode(response);
    }
    final json = response.statusCode == 304 && cached != null
        ? cached.json
        : response.bodyBytes.length >= isolateThreshold
        ? await compute(_responseBody, response)
        : response.body;
    if (epoch == _epoch &&
        pathEpoch == (_pathEpochs[url.path] ?? 0) &&
        _cacheable(url)) {
      _cache.remove(url.toString());
      _cache[url.toString()] = (
        tag:
            response.headers['etag'] ??
            (response.statusCode == 304 ? cached?.tag : null),
        json: json,
        at: DateTime.now(),
      );
      _trim();
      if (cached?.json != json || cached?.tag != _cache[url.toString()]?.tag) {
        _cacheVersion++;
        _save();
      }
      if (cached != null && cached.json != json) {
        _contentRevisions[url.path] = (_contentRevisions[url.path] ?? 0) + 1;
        if (url.hasQuery) {
          final key = url.toString();
          _contentRevisions[key] = (_contentRevisions[key] ?? 0) + 1;
        }
        _updates.add(url);
        if (_isMap(url) ||
            url.path == '/api/render/routes' ||
            url.path == '/api/routes') {
          onMapDataChanged?.call();
        }
      }
    }
    return json;
  }

  void cancelPrefetch() {
    _prefetchTimer?.cancel();
    _prefetchGeneration++;
  }

  // One speculative request at a time, after camera activity has settled.
  void prefetch(Iterable<String> paths) {
    cancelPrefetch();
    final generation = _prefetchGeneration;
    final epoch = _epoch;
    _prefetchTimer = Timer(const Duration(seconds: 2), () async {
      var prepared = 0;
      for (final path in paths) {
        if (generation != _prefetchGeneration || epoch != _epoch) return;
        while (_pending.isNotEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (generation != _prefetchGeneration || epoch != _epoch) return;
        }
        try {
          final json = await _getJson(path, revalidate: false);
          if (generation != _prefetchGeneration || epoch != _epoch) return;
          if (uri(path).path == '/api/render/cells' &&
              prepared < prefetchPreparedSnapshots) {
            await _cells.read('$epoch\n${uri(path)}', json, null);
            prepared++;
          }
        } catch (_) {
          return; // A struggling connection should not spend time on speculation.
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    });
  }

  static Future<dynamic> decodeJson(String json) async =>
      json.length >= isolateThreshold
      ? compute(jsonDecode, json)
      : jsonDecode(json);

  int get revision => _revision;

  Future<Map<String, dynamic>> getMany(
    Map<String, String> paths, {
    bool revalidate = true,
  }) async {
    final entries = paths.entries.toList();
    final values = await Future.wait(
      entries.map((entry) => get(entry.value, revalidate: revalidate)),
    );
    return {for (var i = 0; i < entries.length; i++) entries[i].key: values[i]};
  }

  Future<dynamic> post(
    String path,
    Map<String, dynamic> value, {
    bool invalidate = true,
  }) async {
    // Ground snapshots are determined by their query and stored visits, not
    // display preferences. Saving a switch must not discard every zoom level.
    final paths = path == '/api/prefs'
        ? const {
            '/api/prefs',
            '/api/render/routes',
            '/api/trips',
            '/api/search',
            '/api/render/track',
          }
        : null;
    void invalidateData() =>
        paths == null ? clear() : _invalidatePaths(paths, retainContent: true);
    if (invalidate) invalidateData();
    final epoch = _epoch;
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
    if (invalidate && epoch == _epoch) {
      invalidateData();
      if (path == '/api/prefs' && value['prefs'] is Map) {
        _cache[uri(path).toString()] = (
          tag: null,
          json: jsonEncode(value),
          at: DateTime.now(),
        );
        _trim();
        _cacheVersion++;
        _save();
      }
    }
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

  void dispose() {
    cancelPrefetch();
    _saveTimer?.cancel();
    onMapDataChanged = null;
    _cells.dispose();
    unawaited(_updates.close());
    client.close();
  }
}

String _responseBody(http.Response response) => response.body;
