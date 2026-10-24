import 'iterable.dart';

class FixedList<T> {
  final int maxLength;
  final List<T> _list;

  final int _revision;
  List<T>? _snapshot;

  FixedList(this.maxLength, {List<T>? list})
    : assert(maxLength > 0, 'FixedList without a cap grows without bound'),
      _list = (list ?? [])..truncate(maxLength),
      _revision = 0;

  FixedList._(this.maxLength, this._list, this._revision);

  int get revision => _revision;

  void add(T item) {
    _list.add(item);
    _list.truncate(maxLength);
    _snapshot = null;
  }

  void clear() {
    _list.clear();
    _snapshot = null;
  }

  FixedList<T> append(T item) {
    add(item);
    return FixedList._(maxLength, _list, _revision + 1);
  }

  /// One generation bump for a batch, so a burst of logs/requests does not
  /// rebuild listeners once per event.
  FixedList<T> appendAll(Iterable<T> items) {
    var added = 0;
    for (final item in items) {
      _list.add(item);
      added++;
    }
    if (added == 0) {
      return this;
    }
    _list.truncate(maxLength);
    _snapshot = null;
    return FixedList._(maxLength, _list, _revision + 1);
  }

  FixedList<T> replace(Map<int, T> items) {
    items.forEach((index, item) => _list[index] = item);
    _snapshot = null;
    return FixedList._(maxLength, _list, _revision + 1);
  }

  List<T> get list => _snapshot ??= List.unmodifiable(_list);

  int get length => _list.length;

  T operator [](int index) => _list[index];

  FixedList<T> copyWith() {
    return FixedList(maxLength, list: List.of(_list));
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
