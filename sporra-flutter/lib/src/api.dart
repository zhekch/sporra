import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cupertino_http/cupertino_http.dart';
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
  final _cache = <String, ({String tag, dynamic body})>{};
  Uri uri(String path) => Uri.parse(server).resolve(path);
  void clear() => _cache.clear();
  Future<dynamic> get(String path) async {
    final url = uri(path);
    final cached = _cache[url.toString()];
    final response = await client
        .get(
          url,
          headers: {
            'X-Sporra-Client': 'ios-flutter',
            if (cached != null) 'If-None-Match': cached.tag,
          },
        )
        .timeout(const Duration(seconds: 40));
    if (response.statusCode == 304 && cached != null) return cached.body;
    final body = _decode(response);
    final tag = response.headers['etag'];
    if (tag != null) {
      if (_cache.length > 64) _cache.remove(_cache.keys.first);
      _cache[url.toString()] = (tag: tag, body: body);
    }
    return body;
  }

  Future<dynamic> post(String path, Map<String, dynamic> value) async {
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
