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
    'fresh reads avoid requests and isolate nested caller mutations',
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
      expect(requests, 1);
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

  test('device cache round trips without a network read and survives caller changes', () async {
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
    expect(requests, 0);
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

  test('English string table has not drifted', () async {
    final result = await Process.run('node', ['Tools/gen-arb.mjs', '--check']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
