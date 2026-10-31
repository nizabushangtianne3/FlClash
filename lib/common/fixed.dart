import 'iterable.dart';

class FixedList<T> {
  final int maxLength;
  final Object? Function(T item)? keyOf;
  final List<T> _list;
  final Map<Object, int>? _keyIndexes;

  final int _revision;
  List<T>? _snapshot;

  FixedList(this.maxLength, {List<T>? list, this.keyOf})
    : assert(maxLength > 0, 'FixedList without a cap grows without bound'),
      _list = (list ?? [])..truncate(maxLength),
      _keyIndexes = keyOf == null ? null : {},
      _revision = 0 {
    _reindexKeys();
  }

  FixedList._(
    this.maxLength,
    this._list,
    this._revision,
    this.keyOf,
    this._keyIndexes,
  );

  int get revision => _revision;

  void add(T item) {
    _list.add(item);
    final overflow = _list.length - maxLength;
    if (overflow > 0) {
      _list.removeRange(0, overflow);
      _reindexKeys();
    } else {
      _indexKey(_list.length - 1, item);
    }
    _snapshot = null;
  }

  void clear() {
    _list.clear();
    _keyIndexes?.clear();
    _snapshot = null;
  }

  FixedList<T> append(T item) {
    add(item);
    return _next();
  }

  /// One generation bump for a batch, so a burst of logs/requests does not
  /// rebuild listeners once per event.
  FixedList<T> appendAll(Iterable<T> items) {
    if (items.isEmpty) {
      return this;
    }
    final incomingLength = items.length;
    if (incomingLength >= maxLength) {
      _list.clear();
      _list.addAll(items);
      _list.truncate(maxLength);
    } else {
      final overflow = _list.length + incomingLength - maxLength;
      if (overflow > 0) {
        _list.removeRange(0, overflow);
      }
      _list.addAll(items);
    }
    _reindexKeys();
    _snapshot = null;
    return _next();
  }

  FixedList<T> update(T Function(T item) update) {
    var changed = false;
    for (var index = 0; index < _list.length; index++) {
      final current = _list[index];
      final next = update(current);
      if (identical(current, next)) {
        continue;
      }
      _list[index] = next;
      changed = true;
    }
    if (!changed) {
      return this;
    }
    _snapshot = null;
    return _next();
  }

  FixedList<T> updateByKey<V>(
    Map<Object?, V> values,
    T Function(T item, V value) update,
  ) {
    final indexes = _keyIndexes;
    if (indexes == null) {
      throw StateError('updateByKey requires a FixedList key');
    }
    var changed = false;
    values.forEach((key, value) {
      final index = indexes[key];
      if (index == null) {
        return;
      }
      final current = _list[index];
      final next = update(current, value);
      if (identical(current, next)) {
        return;
      }
      _list[index] = next;
      changed = true;
    });
    if (!changed) {
      return this;
    }
    _snapshot = null;
    return _next();
  }

  FixedList<T> _next() {
    return FixedList._(maxLength, _list, _revision + 1, keyOf, _keyIndexes);
  }

  void _indexKey(int index, T item) {
    final key = keyOf?.call(item);
    if (key != null) {
      _keyIndexes?[key] = index;
    }
  }

  void _reindexKeys() {
    final indexes = _keyIndexes;
    if (indexes == null) {
      return;
    }
    indexes.clear();
    for (var index = 0; index < _list.length; index++) {
      _indexKey(index, _list[index]);
    }
  }

  List<T> get list => _snapshot ??= List.unmodifiable(_list);

  int get length => _list.length;

  T operator [](int index) => _list[index];

  FixedList<T> copyWith() {
    return FixedList(maxLength, list: List.of(_list), keyOf: keyOf);
  }

  @override
  bool operator ==(Object other) =>
      other is FixedList<T> &&
      identical(other._list, _list) &&
      other._revision == _revision;

  @override
  int get hashCode => Object.hash(identityHashCode(_list), _revision);
}

/// Restores the head that [latest] trimmed off [current] so a paused view
/// stays anchored; the result is capped at [limit] from the tail.
List<T> retainTrimmedHead<T>(
  List<T> current,
  List<T> latest,
  int limit, {
  Object Function(T item)? keyOf,
}) {
  if (current.isEmpty || latest.isEmpty) {
    return latest;
  }
  final first = latest.first;
  var index = -1;
  final searchEnd = current.length > limit ? limit : current.length;
  if (keyOf == null) {
    for (var i = 0; i < searchEnd; i++) {
      if (identical(current[i], first)) {
        index = i;
        break;
      }
    }
  } else {
    final firstKey = keyOf(first);
    for (var i = 0; i < searchEnd; i++) {
      if (keyOf(current[i]) == firstKey) {
        index = i;
        break;
      }
    }
  }
  if (index == 0) {
    return latest;
  }
  final headLength = index > 0 ? index : current.length;
  final headEnd = headLength > limit ? limit : headLength;
  if (headEnd <= 0) {
    return List<T>.unmodifiable(const []);
  }
  if (headEnd == limit) {
    return List<T>.unmodifiable(current.sublist(0, headEnd));
  }
  final result = current.sublist(0, headEnd);
  result.addAll(latest.take(limit - headEnd));
  return List<T>.unmodifiable(result);
}
