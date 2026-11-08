import 'dart:collection';

// A single uncacheable response must not evict every useful entry before being
// evicted itself. Reject it before it participates in normal LRU eviction.
class BoundedCache<K, V extends Object> extends MapBase<K, V> {
  BoundedCache({
    required this.maxEntries,
    required this.maxBytes,
    required this.bytesFor,
  });
  final int maxEntries, maxBytes;
  final int Function(V) bytesFor;
  final _entries = <K, V>{};
  int bytes = 0;

  bool canFit(K key, int size) {
    final previous = _entries[key];
    return length + (previous == null ? 1 : 0) <= maxEntries &&
        bytes - (previous == null ? 0 : bytesFor(previous)) + size <= maxBytes;
  }

  bool addIfRoom(K key, V value) {
    if (!canFit(key, bytesFor(value))) return false;
    this[key] = value;
    return true;
  }

  @override
  V? operator [](Object? key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key as K] = value;
    return value;
  }

  @override
  void operator []=(K key, V value) {
    remove(key);
    final size = bytesFor(value);
    if (size > maxBytes || maxEntries <= 0) return;
    _entries[key] = value;
    bytes += size;
    while (length > maxEntries || bytes > maxBytes) {
      remove(_entries.keys.first);
    }
  }

  @override
  V? remove(Object? key) {
    final value = _entries.remove(key);
    if (value != null) bytes -= bytesFor(value);
    return value;
  }

  @override
  void clear() {
    _entries.clear();
    bytes = 0;
  }

  @override
  Iterable<K> get keys => _entries.keys;
  @override
  Iterable<V> get values => _entries.values;
  @override
  Iterable<MapEntry<K, V>> get entries => _entries.entries;
  @override
  int get length => _entries.length;
  @override
  bool containsKey(Object? key) => _entries.containsKey(key);
  @override
  void forEach(void Function(K, V) action) => _entries.forEach(action);

  @override
  void removeWhere(bool Function(K, V) test) {
    final keys = [
      for (final entry in _entries.entries)
        if (test(entry.key, entry.value)) entry.key,
    ];
    for (final key in keys) {
      remove(key);
    }
  }
}
