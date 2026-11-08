import 'package:flutter_test/flutter_test.dart';
import 'package:sporra_flutter/src/bounded_cache.dart';

void main() {
  BoundedCache<String, String> cache() => BoundedCache(
    maxEntries: 3,
    maxBytes: 12,
    bytesFor: (value) => value.length,
  );

  test('normal-sized speculation cannot displace foreground entries', () {
    final entries = cache()..['active'] = 'foreground';
    expect(entries.addIfRoom('neighbour', 'fits'), isFalse);
    expect(entries['active'], 'foreground');
    expect(entries.addIfRoom('neighbour', 'ok'), isTrue);
    expect(entries.bytes, 12);
  });

  test('an oversized response preserves useful startup entries', () {
    final entries = cache()
      ..['prefs'] = 'saved'
      ..['routes'] = 'lines';
    entries['speculation'] = 'too large to cache';
    expect(entries['prefs'], 'saved');
    expect(entries['routes'], 'lines');
    expect(entries.containsKey('speculation'), isFalse);
    expect(entries.bytes, 10);
  });

  test(
    'reads protect recent entries while normal responses obey both bounds',
    () {
      final entries = cache()
        ..['a'] = 'aaaa'
        ..['b'] = 'bbbb'
        ..['c'] = 'cccc';
      expect(entries['a'], 'aaaa');
      entries['d'] = 'dddd';
      expect(entries.keys.toList(), ['c', 'a', 'd']);
      expect(entries.bytes, 12);
      entries['d'] = 'dd';
      entries.removeWhere((key, _) => key == 'a');
      expect(entries.bytes, 6);
      final copied = <String, String>{};
      entries.forEach((key, value) => copied[key] = value);
      expect(copied, {'c': 'cccc', 'd': 'dd'});
      entries.clear();
      expect(entries.bytes, 0);
    },
  );

  test('an oversized replacement drops its old value without purging other entries', () {
    final entries = cache()
      ..['a'] = 'small'
      ..['b'] = 'saved';
    entries['a'] = 'oversized replacement';
    expect(entries.containsKey('a'), isFalse);
    expect(entries['b'], 'saved');
    expect(entries.bytes, 5);
  });
}
