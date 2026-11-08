import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cell_snapshot.dart';
import 'bounded_cache.dart';
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

typedef _Response = ({String? tag, String json, DateTime at});
typedef _SavedResponse = ({String? tag, int size, int id, DateTime at});

String readableError(String message) =>
    RegExp(
      r'SocketException|ClientException|TimeoutException|Connection (?:reset|refused)|network.*(?:lost|connection)',
      caseSensitive: false,
    ).hasMatch(message)
    ? 'Unable to reach your server. Check your connection and retry.'
    : message;

class SporraApi {
  SporraApi({
    http.Client? client,
    int cacheByteLimit = cacheBytes,
    int diskByteLimit = diskCacheBytes,
  }) : client =
           client ??
           (Platform.isIOS
               ? CupertinoClient.defaultSessionConfiguration()
               : http.Client()),
       _cache = BoundedCache<String, _Response>(
         maxEntries: cacheLimit,
         maxBytes: cacheByteLimit,
         bytesFor: (entry) => entry.json.length * 2,
       ),
       _saved = BoundedCache<String, _SavedResponse>(
         maxEntries: cacheLimit,
         maxBytes: diskByteLimit,
         bytesFor: (entry) => entry.size,
       );
  final http.Client client;
  String server = '';
  static const isolateThreshold = 64 * 1024;
  static const cacheLimit = 512;
  static const cacheBytes = 128 * 1024 * 1024;
  static const diskCacheBytes = 256 * 1024 * 1024;
  static const cacheFormat = 2;
  static const prefetchPreparedSnapshots = cellSnapshotLimit - 1;
  static const prefetchResponseLimit = 2;
  static const dataFreshness = Duration(seconds: 60);
  void Function()? onMapDataChanged;
  final _updates = StreamController<Uri>.broadcast();
  Stream<Uri> get updates => _updates.stream;
  final _cells = CellSnapshotReader();
  final _pathEpochs = <String, int>{};
  final _contentRevisions = <String, int>{};
  Timer? _prefetchTimer;
  int _prefetchGeneration = 0;
  final BoundedCache<String, _Response> _cache;
  final BoundedCache<String, _SavedResponse> _saved;
  final _dirty = <int, String>{};
  final _loading = <String, Future<_Response?>>{};
  int _nextFile = 0;
  final _pending = <String, Future<String>>{};
  final _foregroundPending = <String>{};
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
      (_isMap(url) &&
          !(url.path == '/api/render/cells' &&
              url.queryParameters['info'] == '1' &&
              !url.queryParameters.containsKey('bbox'))) ||
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
    final clock = Stopwatch()..start();
    final epoch = _epoch;
    final scope = '$server\n$account';
    _file = file;
    _scope = scope;
    try {
      await _diskWork;
      final saved = await compute(_restoreResponseCache, (
        json: await file.readAsString(),
        scope: scope,
      ));
      if (_epoch != epoch || saved['scope'] != scope) {
        tracePerformance('cache-restore-scope-mismatch', clock);
        return;
      }
      _nextFile = saved['nextFile'] as int? ?? 0;
      for (final row in (saved['entries'] as List).take(cacheLimit)) {
        final url = Uri.parse(row['url'] as String);
        final at = DateTime.fromMillisecondsSinceEpoch(row['at'] as int);
        if (url.origin != uri('/').origin || !_cacheable(url)) {
          continue;
        }
        if (saved['format'] == cacheFormat) {
          final id = row['id'] as int, size = row['size'] as int;
          if (id < 0 || size < 0) continue;
          if (_nextFile <= id) _nextFile = id + 1;
          _saved[url.toString()] = (
            tag: row['tag'] as String?,
            size: size,
            id: id,
            at: at,
          );
        } else {
          _store(url.toString(), (
            tag: row['tag'] as String?,
            json: row['json'] as String,
            at: at,
          ));
        }
      }
      tracePerformance('cache-restored', clock, {
        'entries': _saved.length,
        'estimatedBytes': _saved.bytes,
        'loaded': _cache.length,
      });
      if (saved['format'] != cacheFormat) {
        _cacheVersion++;
        _save();
      }
    } catch (error) {
      tracePerformance('cache-restore-failed ${error.runtimeType}', clock);
      // Device caches are disposable; a missing or damaged file cannot block login.
    }
  }

  void _store(String key, _Response entry, {bool speculative = false}) {
    final previous = _saved[key];
    final reuse = previous != null && _cache[key]?.json == entry.json;
    final record = (
      tag: entry.tag,
      size: entry.json.length * 2,
      id: reuse ? previous.id : _nextFile++,
      at: entry.at,
    );
    if (speculative) {
      _cache.addIfRoom(key, entry);
    } else {
      _cache[key] = entry;
    }
    if (_file == null) return;
    if (speculative) {
      _saved.addIfRoom(key, record);
    } else {
      _saved[key] = record;
    }
    if (!reuse && _saved[key] == record) _dirty[record.id] = entry.json;
    final ids = {for (final saved in _saved.values) saved.id};
    _dirty.removeWhere((id, _) => !ids.contains(id));
  }

  Future<_Response?> _loadSaved(String key, {bool speculative = false}) async {
    final saved = _saved[key], file = _file;
    if (saved == null || file == null) return null;
    final epoch = _epoch;
    final path = Uri.parse(key).path;
    final pathEpoch = _pathEpochs[path] ?? 0;
    final work = _loading[key] ??= () async {
      final clock = Stopwatch()..start();
      try {
        final pending = _dirty[saved.id];
        final body = File('${file.path}.data/${saved.id}.json');
        if (pending == null && !await body.exists()) await _diskWork;
        final json = pending ?? await _readBody(body);
        if (json.length * 2 != saved.size) {
          throw const FormatException('Incomplete cache body.');
        }
        if (epoch != _epoch ||
            pathEpoch != (_pathEpochs[path] ?? 0) ||
            _saved[key] != saved) {
          return null;
        }
        final entry = (tag: saved.tag, json: json, at: saved.at);
        if (speculative) {
          _cache.addIfRoom(key, entry);
        } else {
          _cache[key] = entry;
        }
        tracePerformance('cache-body-read $path', clock, {
          'estimatedBytes': json.length * 2,
        });
        return entry;
      } catch (error) {
        if (epoch == _epoch && _saved[key] == saved) {
          _saved.remove(key);
          _cacheVersion++;
          _save();
        }
        tracePerformance('cache-body-failed ${error.runtimeType}', clock);
        return null;
      }
    }();
    try {
      return await work;
    } finally {
      if (identical(_loading[key], work)) _loading.remove(key);
    }
  }

  static Future<String> _readBody(File file) async {
    final bytes = await file.readAsBytes();
    return bytes.length >= isolateThreshold
        ? compute(_responseText, bytes)
        : utf8.decode(bytes);
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
      'format': cacheFormat,
      'nextFile': _nextFile,
      'entries': [
        for (final entry in _saved.entries)
          {
            'url': entry.key,
            'tag': entry.value.tag,
            'id': entry.value.id,
            'size': entry.value.size,
            'at': entry.value.at.millisecondsSinceEpoch,
          },
      ],
    };
    final ids = {for (final entry in _saved.values) entry.id};
    final bodies = {
      for (final id in ids)
        if (_dirty.containsKey(id)) id: _dirty[id]!,
    };
    _dirty.clear();
    return _diskWork = _diskWork.then((_) async {
      final clock = Stopwatch()..start();
      try {
        final json = jsonEncode(snapshot);
        await file.parent.create(recursive: true);
        final directory = Directory('${file.path}.data');
        await directory.create(recursive: true);
        for (final entry in bodies.entries) {
          final body = File('${directory.path}/${entry.key}.json');
          final temporary = File('${body.path}.tmp');
          final bytes = await compute(_responseBytes, entry.value);
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(body.path);
        }
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(json, flush: true);
        await temporary.rename(file.path);
        await for (final entity in directory.list()) {
          final name = entity.path.split(Platform.pathSeparator).last;
          final match = RegExp(r'^(\d+)\.json(?:\.tmp)?$').firstMatch(name);
          if (entity is File &&
              match != null &&
              !ids.contains(int.parse(match[1]!))) {
            await entity.delete();
          }
        }
        tracePerformance('cache-saved', clock, {
          'entries': (snapshot['entries'] as List).length,
          'bodies': bodies.length,
        });
      } catch (error) {
        tracePerformance('cache-save-failed ${error.runtimeType}', clock);
      }
    });
  }

  void clear() {
    _epoch++;
    _revision++;
    _cacheVersion++;
    _queuedSaveVersion = _cacheVersion;
    _pathEpochs.clear();
    _contentRevisions.clear();
    _cells.clear();
    cancelPrefetch();
    _cache.clear();
    _saved.clear();
    _dirty.clear();
    _loading.clear();
    _pending.clear();
    _foregroundPending.clear();
    _saveTimer?.cancel();
    final file = _file;
    if (file != null) {
      _diskWork = _diskWork.then((_) async {
        try {
          if (await file.exists()) await file.delete();
          final directory = Directory('${file.path}.data');
          if (await directory.exists()) await directory.delete(recursive: true);
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
    _saved.removeWhere(
      (key, _) =>
          affected(key) &&
          (!retainContent || Uri.parse(key).path == '/api/prefs'),
    );
    _loading.removeWhere((key, _) => affected(key));
    final ids = {for (final saved in _saved.values) saved.id};
    _dirty.removeWhere((id, _) => !ids.contains(id));
    _pending.removeWhere((key, _) => affected(key));
    _foregroundPending.removeWhere(affected);
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

  bool hasCached(String path) {
    final key = uri(path).toString();
    return _cache.containsKey(key) || _saved.containsKey(key);
  }

  Future<void> prepareCells(String path) async {
    final key = uri(path).toString();
    final cached = _cache[key] ?? await _loadSaved(key);
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
    bool speculative = false,
  }) async {
    final url = uri(path);
    final key = url.toString();
    final epoch = _epoch;
    _saved[key]; // Retain the active response in the disk LRU too.
    final cached =
        _cache[key] ?? await _loadSaved(key, speculative: speculative);
    if (_cacheable(url)) {
      tracePerformance('cache ${url.path}', Stopwatch(), {
        'hit': cached == null ? 0 : 1,
      });
    }
    if (!refresh && cached != null && _cacheable(url)) {
      if (revalidate) this.revalidate(path);
      // Callers filter and decorate GeoJSON; never lend them the cached object.
      return cached.json;
    }
    if (!speculative) _foregroundPending.add(key);
    final work = _pending[key] ??= _read(
      url,
      cached,
      epoch,
      _pathEpochs[url.path] ?? 0,
    );
    try {
      return await work;
    } finally {
      if (identical(_pending[key], work)) {
        _pending.remove(key);
        _foregroundPending.remove(key);
      }
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
    tracePerformance('http $endpoint', clock, {
      'status': response.statusCode,
      'bytes': response.bodyBytes.length,
    });
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
      final entry = (
        tag:
            response.headers['etag'] ??
            (response.statusCode == 304 ? cached?.tag : null),
        json: json,
        at: DateTime.now(),
      );
      _store(
        url.toString(),
        entry,
        speculative: !_foregroundPending.contains(url.toString()),
      );
      tracePerformance('cache-store $endpoint', clock, {
        'estimatedBytes': json.length * 2,
        'retained': _cache.containsKey(url.toString()) ? 1 : 0,
        'entries': _cache.length,
      });
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
        if ((_isMap(url) &&
                !(url.path == '/api/render/cells' &&
                    url.queryParameters['info'] == '1')) ||
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
      for (final path in paths.take(prefetchResponseLimit)) {
        if (generation != _prefetchGeneration || epoch != _epoch) return;
        while (_pending.isNotEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (generation != _prefetchGeneration || epoch != _epoch) return;
        }
        try {
          final json = await _getJson(
            path,
            revalidate: false,
            speculative: true,
          );
          if (generation != _prefetchGeneration || epoch != _epoch) return;
          if (uri(path).path == '/api/render/cells' &&
              prepared < prefetchPreparedSnapshots) {
            await _cells.read(
              '$epoch\n${uri(path)}',
              json,
              null,
              speculative: true,
            );
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
        _store(uri(path).toString(), (
          tag: null,
          json: jsonEncode(value),
          at: DateTime.now(),
        ));
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
Uint8List _responseBytes(String text) => utf8.encode(text);
String _responseText(Uint8List bytes) => utf8.decode(bytes);

// Previous builds saved every cell's visit history with the geometry. Extract
// their usable geometry during restoration, before that history crosses back
// to the UI isolate. The geometry query has its own ETag, so do not reuse it.
Map<String, dynamic> _restoreResponseCache(
  ({String json, String scope}) input,
) {
  final saved = jsonDecode(input.json) as Map<String, dynamic>;
  if (saved['scope'] != input.scope) return {'scope': saved['scope']};
  if (saved['format'] == SporraApi.cacheFormat) return saved;
  final entries = saved['entries'] as List;
  final existing = {for (final row in entries) row['url']};
  var migrated = false;
  final restored = <Map<String, dynamic>>[];
  for (final row in entries) {
    final url = Uri.parse(row['url'] as String);
    if (url.path != '/api/render/cells' ||
        url.queryParameters['info'] != '1' ||
        url.queryParameters.containsKey('bbox')) {
      restored.add(Map<String, dynamic>.from(row));
      continue;
    }
    migrated = true;
    final geometryUrl = url
        .replace(
          queryParameters: {
            ...url.queryParametersAll,
            'info': ['0'],
          },
        )
        .toString();
    if (existing.contains(geometryUrl)) continue;
    try {
      final geometry = jsonDecode(row['json'] as String) as Map;
      geometry['columns'] = ['key', 'x', 'y', 'color', 'sparse'];
      geometry['rows'] = [
        for (final cell in geometry['rows'] as List)
          (cell as List).take(5).toList(),
      ];
      restored.add({
        ...Map<String, dynamic>.from(row),
        'url': geometryUrl,
        'tag': null,
        'json': jsonEncode(geometry),
      });
    } catch (_) {
      // One damaged legacy snapshot must not discard other saved content.
    }
  }
  return {...saved, 'entries': restored, 'migrated': migrated};
}
