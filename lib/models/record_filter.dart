import 'package:collection/collection.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/foundation.dart';

const recordFacetMaxOptions = 12;

@immutable
class RecordFilter {
  final RecordFacetKind kind;
  final String value;

  const RecordFilter(this.kind, this.value);

  @override
  bool operator ==(Object other) =>
      other is RecordFilter && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'RecordFilter(${kind.name}: $value)';
}

/// Filters on one facet widen each other, on different facets narrow.
class RecordFacet<T> {
  final RecordFacetKind kind;

  /// The one value this facet reads from a row, empty when the row has none;
  /// null for a facet that reads several.
  final String Function(T item)? valueOf;

  /// The several values this facet reads from a row; null when it reads one.
  final List<String> Function(T item)? valuesOf;

  /// Only a facet whose values come from a fixed set is offered in the menu;
  /// one growing with the user's apps or profiles is filtered from a row.
  final bool offered;

  final List<String> order;
  final String Function(String value)? labelOf;

  const RecordFacet(
    this.kind,
    this.valuesOf, {
    this.offered = false,
    this.order = const [],
    this.labelOf,
  }) : valueOf = null;

  /// A facet that reads a single value: counting a table does not have to
  /// build a one-element list per row.
  const RecordFacet.single(
    this.kind,
    this.valueOf, {
    this.offered = false,
    this.order = const [],
    this.labelOf,
  }) : valuesOf = null;

  String label(String value) => labelOf?.call(value) ?? value;

  /// Whether a row answers any of [selected] on this facet.
  bool matches(T item, Set<String> selected) {
    final single = valueOf;
    return single != null
        ? selected.contains(single(item))
        : valuesOf!(item).any(selected.contains);
  }

  void countInto(Iterable<T> items, Map<String, int> counts) {
    final single = valueOf;
    if (single != null) {
      for (final item in items) {
        final value = single(item);
        if (value.isNotEmpty) {
          counts[value] = (counts[value] ?? 0) + 1;
        }
      }
      return;
    }
    for (final item in items) {
      for (final value in valuesOf!(item)) {
        if (value.isNotEmpty) {
          counts[value] = (counts[value] ?? 0) + 1;
        }
      }
    }
  }

  List<String> optionsOf(
    Iterable<T> items, {
    Iterable<String> selected = const [],
    int max = recordFacetMaxOptions,
  }) {
    final counts = <String, int>{};
    countInto(items, counts);
    final frequent = _mostFrequent(counts, max);
    final options = {...frequent, ...selected}.toList();
    int rank(String value) {
      final index = order.indexOf(value);
      return index < 0 ? order.length : index;
    }

    return options..sort((a, b) {
      final ranked = rank(a) - rank(b);
      return ranked != 0 ? ranked : a.toLowerCase().compareTo(b.toLowerCase());
    });
  }

  /// The [max] values with the highest counts, most frequent first. A table
  /// holds hundreds of distinct values on a facet it offers, and only [max]
  /// of them are shown, so the pass stays bounded instead of sorting them all.
  /// A value already held keeps its place over one that only ties it.
  /// With no more values than are shown, the counts order nothing: every one
  /// of them is offered and the options sort themselves.
  List<String> _mostFrequent(Map<String, int> counts, int max) {
    if (counts.length <= max) {
      return counts.keys.toList();
    }
    final best = <MapEntry<String, int>>[];
    for (final entry in counts.entries) {
      if (best.length >= max && entry.value <= best.last.value) {
        continue;
      }
      var index = best.length;
      while (index > 0 && best[index - 1].value < entry.value) {
        index--;
      }
      best.insert(index, entry);
      if (best.length > max) {
        best.removeAt(max);
      }
    }
    return [for (final entry in best) entry.key];
  }
}

class RecordGrouper<T> {
  final RecordGrouping grouping;
  final String Function(T item) keyOf;

  const RecordGrouper(this.grouping, this.keyOf);
}

class RecordGroup<T> {
  final String key;

  /// Top first.
  final List<T> items;

  const RecordGroup(this.key, this.items);
}

/// Groups follow their item shown highest; [reverse] marks a list shown
/// bottom up.
List<RecordGroup<T>> groupRecords<T>(
  List<T> items,
  String Function(T item) keyOf, {
  bool reverse = false,
}) {
  final groups = <String, List<T>>{};
  for (final item in reverse ? items.reversed : items) {
    (groups[keyOf(item)] ??= []).add(item);
  }
  return [
    for (final MapEntry(:key, :value) in groups.entries)
      RecordGroup(key, value),
  ];
}

extension RecordFilterIterableExt<T> on Iterable<T> {
  Iterable<T> whereFilters(
    List<RecordFacet<T>> facets,
    List<RecordFilter> filters,
  ) {
    if (filters.isEmpty) {
      return this;
    }
    final selected = <RecordFacet<T>, Set<String>>{};
    for (final filter in filters) {
      final facet = facets.firstWhereOrNull(
        (facet) => facet.kind == filter.kind,
      );
      if (facet != null) {
        (selected[facet] ??= {}).add(filter.value);
      }
    }
    return where(
      (item) => selected.entries.every(
        (entry) => entry.key.matches(item, entry.value),
      ),
    );
  }
}
