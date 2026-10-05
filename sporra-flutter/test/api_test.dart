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
      expect(await api.get('/api/render/cells'), {
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
  test('English string table has not drifted', () async {
    final result = await Process.run('node', ['Tools/gen-arb.mjs', '--check']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
