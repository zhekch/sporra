import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sporra_flutter/src/api.dart';

void main() {
  test(
    'conditional reads reuse a 304 body and clear after mutations',
    () async {
      var n = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') return http.Response('{"ok":true}', 200);
        n++;
        if (n == 2) {
          expect(request.headers['If-None-Match'], 'W/"a"');
          return http.Response('', 304);
        }
        expect(request.headers.containsKey('If-None-Match'), isFalse);
        return http.Response('{"rows":[1]}', 200, headers: {'etag': 'W/"a"'});
      });
      final api = SporraApi(client: client)..server = 'https://example.test';
      expect(await api.get('/api/render/cells'), {
        'rows': [1],
      });
      expect(await api.get('/api/render/cells', refresh: true), {
        'rows': [1],
      });
      await api.post('/api/render/brush', {});
      await api.get('/api/render/cells');
    },
  );
  test('a signed-out response becomes an actionable API exception', () async {
    final api = SporraApi(
      client: MockClient(
        (_) async => http.Response('{"error":"not authenticated"}', 401),
      ),
    )..server = 'https://example.test';
    await expectLater(
      api.get('/api/me'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
    );
  });
  test(
    'even fresh cached reads validate without sharing caller mutations',
    () async {
      var requests = 0;
      final api = SporraApi(
        client: MockClient((_) async {
          requests++;
          return http.Response(
            '{"features":[{"properties":{"color":"blue"}}]}',
            200,
          );
        }),
      )..server = 'https://example.test';
      final first = await api.get('/api/render/routes');
      first['features'][0]['properties']['color'] = 'red';
      first['features'].clear();
      final second = await api.get('/api/render/routes');
      expect(second['features'][0]['properties']['color'], 'blue');
      await Future<void>.delayed(Duration.zero);
      expect(requests, 2);
      api.dispose();
    },
  );

  test(
    'simultaneous reads share a download but own their decoded objects',
    () async {
      var requests = 0;
      final response = Completer<http.Response>();
      final api = SporraApi(
        client: MockClient((_) {
          requests++;
          return response.future;
        }),
      )..server = 'https://example.test';
      final a = api.get('/api/days');
      final b = api.get('/api/days');
      response.complete(http.Response('{"days":{"2026-01-01":1}}', 200));
      final results = await Future.wait([a, b]);
      results[0]['days'].clear();
      expect(results[1]['days'], {'2026-01-01': 1});
      expect(requests, 1);
    },
  );

  test('a read crossing invalidation cannot repopulate the cache', () async {
    var requests = 0;
    final response = Completer<http.Response>();
    final api = SporraApi(
      client: MockClient((_) {
        requests++;
        return requests == 1
            ? response.future
            : Future.value(http.Response('{"days":{"new":1}}', 200));
      }),
    )..server = 'https://example.test';
    final old = api.get('/api/days');
    await Future<void>.delayed(Duration.zero);
    api.clear();
    response.complete(http.Response('{"days":{"old":1}}', 200));
    await old;
    expect((await api.get('/api/days'))['days'], {'new': 1});
    expect(requests, 2);
  });

  test(
    'restored data is scoped to server and account, with ETag revalidation',
    () async {
      final directory = await Directory.systemTemp.createTemp('sporra-cache-');
      final file = File('${directory.path}/responses.json');
      addTearDown(() => directory.delete(recursive: true));
      await file.writeAsString(
        jsonEncode({
          'scope': 'https://example.test\nalice',
          'entries': [
            {
              'url': 'https://example.test/api/days',
              'tag': 'W/"saved"',
              'json': '{"days":{"saved":1}}',
              'at': DateTime.now()
                  .subtract(const Duration(minutes: 2))
                  .millisecondsSinceEpoch,
            },
          ],
        }),
      );
      final api = SporraApi(
        client: MockClient((request) async {
          expect(request.headers['If-None-Match'], 'W/"saved"');
          return http.Response('', 304);
        }),
      )..server = 'https://example.test';
      await api.restore(file, 'alice');
      expect((await api.get('/api/days'))['days'], {'saved': 1});
      final other = SporraApi(
        client: MockClient((request) async {
          expect(request.headers.containsKey('If-None-Match'), isFalse);
          return http.Response('{"days":{"bob":1}}', 200);
        }),
      )..server = 'https://example.test';
      await other.restore(file, 'bob');
      expect((await other.get('/api/days'))['days'], {'bob': 1});
      api.clear();
      other.clear();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
  );

  test(
    'session checks always reach the server and 401 clears cached data',
    () async {
      var authenticated = true;
      var requests = 0;
      final api = SporraApi(
        client: MockClient((request) async {
          requests++;
          if (!authenticated) {
            return http.Response('{"error":"signed out"}', 401);
          }
          return http.Response('{"days":{}}', 200);
        }),
      )..server = 'https://example.test';
      await api.get('/api/days');
      await api.get('/api/me');
      await api.get('/api/me');
      expect(requests, 3);
      authenticated = false;
      await expectLater(api.get('/api/me'), throwsA(isA<ApiException>()));
      await expectLater(api.get('/api/days'), throwsA(isA<ApiException>()));
      expect(requests, 5);
    },
  );

  test('device cache round trips before server validation and survives caller changes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sporra-roundtrip-',
    );
    final file = File('${directory.path}/responses.json');
    addTearDown(() => directory.delete(recursive: true));
    final api = SporraApi(
      client: MockClient((_) async => http.Response('{"trips":[1]}', 200)),
    )..server = 'https://example.test';
    await api.restore(file, 'alice');
    (await api.get('/api/trips'))['trips'].clear();
    await api.flushCache();
    var requests = 0;
    final restored = SporraApi(
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 500);
      }),
    )..server = 'https://example.test';
    await restored.restore(file, 'alice');
    expect((await restored.get('/api/trips'))['trips'], [1]);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    api.dispose();
    restored.dispose();
  });

  test('transport failures can use retained data but authorization failures cannot', () async {
    var offline = false;
    final api = SporraApi(
      client: MockClient((_) async {
        if (offline) throw const SocketException('offline');
        return http.Response('{"days":{"saved":1}}', 200);
      }),
    )..server = 'https://example.test';
    await api.get('/api/days');
    offline = true;
    expect((await api.get('/api/days', refresh: true))['days'], {'saved': 1});
    api.clear();
    await expectLater(api.get('/api/days'), throwsA(isA<SocketException>()));
  });

  test(
    'old map snapshots paint before conditional background validation',
    () async {
      final directory = await Directory.systemTemp.createTemp('sporra-map-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/responses.json');
      await file.writeAsString(
        jsonEncode({
          'scope': 'https://example.test\nalice',
          'entries': [
            {
              'url': 'https://example.test/api/render/cells?level=3',
              'tag': '"saved"',
              'json': '{"rows":[1]}',
              'at': DateTime.now()
                  .subtract(const Duration(days: 800))
                  .millisecondsSinceEpoch,
            },
          ],
        }),
      );
      final reply = Completer<http.Response>();
      var requests = 0, changes = 0;
      final api = SporraApi(
        client: MockClient((request) {
          requests++;
          expect(request.headers['If-None-Match'], '"saved"');
          return reply.future;
        }),
      )..server = 'https://example.test';
      api.onMapDataChanged = () => changes++;
      await api.restore(file, 'alice');
      expect((await api.get('/api/render/cells?level=3'))['rows'], [1]);
      expect((await api.get('/api/render/cells?level=3'))['rows'], [1]);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
      reply.complete(http.Response('{"rows":[2]}', 200));
      await api.get('/api/render/cells?level=3', refresh: true);
      expect(changes, 1);
      expect((await api.get('/api/render/cells?level=3'))['rows'], [2]);
      await api.flushCache();
      api.dispose();
    },
  );

  test(
    'invalidated background maps cannot notify or restore old data',
    () async {
      final reply = Completer<http.Response>();
      var requests = 0, changes = 0;
      final api = SporraApi(
        client: MockClient((_) {
          requests++;
          return requests == 2
              ? reply.future
              : Future.value(http.Response('{"rows":[1]}', 200));
        }),
      )..server = 'https://example.test';
      api.onMapDataChanged = () => changes++;
      await api.get('/api/render/regions');
      final pending = api.get('/api/render/regions', refresh: true);
      await Future<void>.delayed(Duration.zero);
      api.clear();
      reply.complete(http.Response('{"rows":[2]}', 200));
      await pending;
      expect(changes, 0);
      expect((await api.get('/api/render/regions'))['rows'], [1]);
      expect(requests, 3);
    },
  );

  test('cancelled speculative downloads never start', () async {
    var requests = 0;
    final api = SporraApi(
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    )..server = 'https://example.test';
    api.prefetch(['/api/render/cells?level=1']);
    api.cancelPrefetch();
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(requests, 0);
  });

  test(
    'every retained content endpoint displays year-old data before validation',
    () async {
      final directory = await Directory.systemTemp.createTemp('sporra-stale-');
      addTearDown(() => directory.delete(recursive: true));
      final paths = [
        '/api/prefs',
        '/api/days',
        '/api/search?q=place',
        '/api/render/activity?id=1',
        '/api/render/track?day=2020-01-01',
        '/api/render/cells?level=0',
      ];
      final file = File('${directory.path}/responses.json');
      await file.writeAsString(
        jsonEncode({
          'scope': 'https://example.test\nalice',
          'entries': [
            for (final path in paths)
              {
                'url': 'https://example.test$path',
                'tag': '"saved"',
                'json': '{"value":"saved"}',
                'at': DateTime.now()
                    .subtract(const Duration(days: 800))
                    .millisecondsSinceEpoch,
              },
          ],
        }),
      );
      final reply = Completer<http.Response>();
      final requested = <String>[];
      final changed = <Uri>[];
      final api = SporraApi(
        client: MockClient((request) {
          requested.add(request.url.toString());
          expect(request.headers['If-None-Match'], '"saved"');
          return reply.future;
        }),
      )..server = 'https://example.test';
      addTearDown(api.dispose);
      api.updates.listen(changed.add);
      await api.restore(file, 'alice');
      for (final path in paths) {
        expect(await api.get(path).timeout(const Duration(seconds: 1)), {
          'value': 'saved',
        });
        expect(await api.get(path), {'value': 'saved'});
      }
      await Future<void>.delayed(Duration.zero);
      expect(requested.length, paths.length);
      expect(reply.isCompleted, isFalse);
      reply.complete(http.Response('{"value":"latest"}', 200));
      await Future.wait(paths.map((path) => api.get(path, refresh: true)));
      await Future<void>.delayed(Duration.zero);
      expect(changed.length, paths.length);
      for (final path in paths) {
        expect(await api.get(path, revalidate: false), {'value': 'latest'});
      }
      expect(requested.length, paths.length);
    },
  );

  test(
    'unchanged validation retains the disk file and other zoom identities',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sporra-unchanged-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/responses.json');
      var changed = false;
      final api = SporraApi(
        client: MockClient((request) async {
          if (request.headers.containsKey('If-None-Match')) {
            return changed
                ? http.Response('{"rows":[2]}', 200)
                : http.Response('', 304);
          }
          return http.Response(
            '{"rows":[1]}',
            200,
            headers: {'etag': '"saved"'},
          );
        }),
      )..server = 'https://example.test';
      addTearDown(api.dispose);
      await api.restore(file, 'alice');
      await api.get('/api/render/cells?level=0');
      await api.flushCache();
      final original = await file.readAsString();
      await api.get('/api/render/cells?level=0', refresh: true);
      await api.flushCache();
      expect(await file.readAsString(), original);
      final other = api.revisionFor('/api/render/cells?level=1');
      final active = api.revisionFor('/api/render/cells?level=0');
      changed = true;
      await api.get('/api/render/cells?level=0', refresh: true);
      expect(api.revisionFor('/api/render/cells?level=0'), isNot(active));
      expect(api.revisionFor('/api/render/cells?level=1'), other);
    },
  );

  test('English string table has not drifted', () async {
    final result = await Process.run('node', ['Tools/gen-arb.mjs', '--check']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });

  test('accepted preference writes retain startup appearance and activity lines across restart', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sporra-prefs-startup-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/responses.json');
    final api = SporraApi(
      client: MockClient((request) async {
        if (request.method == 'POST') return http.Response('{"ok":true}', 200);
        return http.Response('{"features":[1]}', 200);
      }),
    )..server = 'https://example.test';
    addTearDown(api.dispose);
    await api.restore(file, 'alice');
    await api.get('/api/render/routes');
    await api.post('/api/prefs', {
      'prefs': {'heatMode': 'visits', 'mapboxToken': 'pk.fixture'},
    });
    await api.flushCache();
    final response = Completer<http.Response>();
    final restored = SporraApi(client: MockClient((_) => response.future))
      ..server = api.server;
    addTearDown(restored.dispose);
    await restored.restore(file, 'alice');
    expect(
      (await restored
          .get('/api/prefs')
          .timeout(const Duration(seconds: 1)))['prefs']['heatMode'],
      'visits',
    );
    expect(
      (await restored
          .get('/api/render/routes')
          .timeout(const Duration(seconds: 1)))['features'],
      [1],
    );
    expect(response.isCompleted, isFalse);
    response.complete(http.Response('{}', 503));
    await Future<void>.delayed(Duration.zero);
  });
}
