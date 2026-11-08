import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'bounded_cache.dart';
import 'performance.dart';

const _world = 40075016.68557849;
const _indexColumns = 256;
const _bucketSize = _world / _indexColumns;
const cellSnapshotBytes = 64 * 1024 * 1024;
const cellSnapshotLimit = 3;

// Full account snapshots stay in this isolate. Only the padded viewport crosses
// back to Flutter, and revisiting a zoom level reuses its decoded spatial index.
class CellSnapshotReader {
  Future<SendPort>? _worker;
  Isolate? _isolate;
  ReceivePort? _replies;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _next = 0;
  bool _disposed = false;

  Future<SendPort> _start() async {
    final ready = Completer<SendPort>();
    final replies = _replies = ReceivePort();
    replies.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      final reply = message as List;
      final pending = _pending.remove(reply[0]);
      if (reply[2] == null) {
        pending?.complete(Map<String, dynamic>.from(reply[1] as Map));
      } else {
        pending?.completeError(FormatException(reply[2] as String));
      }
    });
    final isolate = await Isolate.spawn(_readSnapshots, replies.sendPort);
    if (_disposed) {
      isolate.kill(priority: Isolate.immediate);
      replies.close();
      throw StateError('Cell reader is closed.');
    }
    _isolate = isolate;
    return ready.future;
  }

  Future<Map<String, dynamic>> read(
    String key,
    String json,
    List<double>? bounds, {
    bool speculative = false,
  }) async {
    if (_disposed) throw StateError('Cell reader is closed.');
    final worker = await (_worker ??= _start());
    if (_disposed) throw StateError('Cell reader is closed.');
    final id = _next++;
    final result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    worker.send([id, key, json, bounds, speculative]);
    return result.future;
  }

  void clear() {
    final worker = _worker;
    if (worker != null) {
      unawaited(
        worker.then<void>((port) => port.send(null), onError: (Object _) {}),
      );
    }
  }

  void dispose() {
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _replies?.close();
    for (final result in _pending.values) {
      result.completeError(StateError('Cell reader is closed.'));
    }
    _pending.clear();
  }
}

void _readSnapshots(SendPort replies) {
  final requests = ReceivePort();
  final cache = BoundedCache<String, _CellSnapshot>(
    maxEntries: cellSnapshotLimit,
    maxBytes: cellSnapshotBytes,
    bytesFor: (snapshot) => snapshot.json.length * 2,
  );
  replies.send(requests.sendPort);
  requests.listen((message) {
    if (message == null) {
      cache.clear();
      return;
    }
    final request = message as List;
    final id = request[0] as int;
    try {
      final key = request[1] as String, json = request[2] as String;
      final clock = Stopwatch()..start();
      if (request[3] == null &&
          (json.length * 2 > cellSnapshotBytes ||
              (request[4] == true && !cache.canFit(key, json.length * 2)))) {
        tracePerformance('cell-index-preparation-skipped', clock, {
          'estimatedBytes': json.length * 2,
        });
        replies.send([id, <String, dynamic>{}, null]);
        return;
      }
      var snapshot = cache.remove(key);
      final reused = snapshot != null && snapshot.json == json;
      if (snapshot == null || snapshot.json != json) {
        snapshot = _CellSnapshot(json);
      }
      if (request[4] == true) {
        cache.addIfRoom(key, snapshot);
      } else {
        cache[key] = snapshot;
      }
      tracePerformance('cell-index', clock, {
        'hit': reused ? 1 : 0,
        'estimatedBytes': json.length * 2,
        'retained': cache.containsKey(key) ? 1 : 0,
      });
      replies.send([
        id,
        request[3] == null
            ? <String, dynamic>{}
            : snapshot.viewport(List<double>.from(request[3])),
        null,
      ]);
    } catch (error) {
      replies.send([id, null, '$error']);
    }
  });
}

double _mercY(double lat) =>
    math.log(
      math.tan(math.pi / 4 + lat.clamp(-85.051129, 85.051129) * math.pi / 360),
    ) *
    _world /
    (2 * math.pi);

class _CellSnapshot {
  _CellSnapshot(this.json) : data = jsonDecode(json) as Map<String, dynamic> {
    final rows = data['rows'] as List;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i] as List;
      final x = (row[1] as num).toDouble() % _world;
      final y = (row[2] as num).toDouble();
      (buckets[(x ~/ _bucketSize, (y / _bucketSize).floor())] ??= []).add(i);
    }
  }
  final String json;
  final Map<String, dynamic> data;
  final buckets = <(int, int), List<int>>{};

  Map<String, dynamic> viewport(List<double> bounds) {
    final rows = data['rows'] as List;
    final west = (bounds[0] / 360 * _world) % _world;
    final span =
        (bounds[2] - bounds[0] == 360 ? 360.0 : (bounds[2] - bounds[0]) % 360) /
        360 *
        _world;
    final south = _mercY(bounds[1]), north = _mercY(bounds[3]);
    bool inside(int index) {
      final row = rows[index] as List;
      final x = (row[1] as num).toDouble() % _world;
      final y = (row[2] as num).toDouble();
      var offset = x - west;
      if (offset < -1e-7) offset += _world;
      return y >= south - 1e-7 &&
          y <= north + 1e-7 &&
          (span >= _world || offset <= span + 1e-7);
    }

    final selected = <int>[];
    if (span >= _world / 4) {
      for (var i = 0; i < rows.length; i++) {
        if (inside(i)) selected.add(i);
      }
    } else {
      void scan(double start, double end) {
        final firstY = (south / _bucketSize).floor();
        final lastY = (north / _bucketSize).floor();
        for (
          var x = start ~/ _bucketSize;
          x <= math.min(_indexColumns - 1, end ~/ _bucketSize);
          x++
        ) {
          for (var y = firstY; y <= lastY; y++) {
            for (final index in buckets[(x, y)] ?? const <int>[]) {
              if (inside(index)) selected.add(index);
            }
          }
        }
      }

      scan(west, math.min(_world, west + span));
      if (west + span >= _world) scan(0, west + span - _world);
      // Disc compositing follows the server's ordering, independent of buckets.
      selected.sort();
    }
    return {
      ...data,
      'rows': [for (final index in selected) rows[index]],
    };
  }
}
