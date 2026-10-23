import 'package:fl_clash/ui/table_layout.dart';
import 'package:fl_clash/widgets/record_table.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Item {
  const _Item(this.value, this.newest);

  final int value;
  final int newest;
}

RecordColumn<_Item> _column() {
  return RecordColumn<_Item>(
    const TableColumn('value', 'Value', flex: 1),
    cell: (_, _) => const SizedBox.shrink(),
    sortKey: (item) => item.value,
  );
}

void main() {
  test('the default order keeps the newest rows up to the limit', () {
    final sorter = RecordSorter<_Item>();
    final items = [for (var value = 0; value < 6; value++) _Item(value, value)];

    final sorted = sorter.sort(
      items,
      const [],
      null,
      limit: 3,
      newestKey: (item) => item.value,
    );

    expect(sorted.map((item) => item.value), [5, 4, 3]);
  });

  test('the default order sorts a full list newest first', () {
    final sorter = RecordSorter<_Item>();
    final items = [const _Item(1, 0), const _Item(3, 2), const _Item(2, 1)];

    final sorted = sorter.sort(
      items,
      const [],
      null,
      limit: 3,
      newestKey: (item) => item.newest,
    );

    expect(sorted.map((item) => item.newest), [2, 1, 0]);
  });

  test('a column sort keeps its best rows up to the limit', () {
    final sorter = RecordSorter<_Item>();
    final items = [for (var value = 0; value < 6; value++) _Item(value, value)];

    final sorted = sorter.sort(
      items,
      [_column()],
      (columnId: 'value', descending: true),
      limit: 3,
    );

    expect(sorted.map((item) => item.value), [5, 4, 3]);
  });

  test('a full column sort puts its best rows first', () {
    final sorter = RecordSorter<_Item>();
    final items = [const _Item(1, 0), const _Item(3, 2), const _Item(2, 1)];

    final sorted = sorter.sort(
      items,
      [_column()],
      (columnId: 'value', descending: true),
      limit: 3,
    );

    expect(sorted.map((item) => item.value), [3, 2, 1]);
  });

  test('a bounded column sort keeps source order for equal keys', () {
    final sorter = RecordSorter<_Item>();
    final items = [
      const _Item(2, 0),
      const _Item(1, 1),
      const _Item(3, 2),
      const _Item(2, 3),
      const _Item(2, 4),
    ];

    final sorted = sorter.sort(
      items,
      [_column()],
      (columnId: 'value', descending: true),
      limit: 3,
    );

    expect(sorted.map((item) => item.value), [3, 2, 2]);
    expect(identical(sorted[1], items[0]), isTrue);
    expect(identical(sorted[2], items[3]), isTrue);
  });

  test('a bounded column sort uses the newest key for equal keys', () {
    final sorter = RecordSorter<_Item>();
    final items = [
      const _Item(2, 0),
      const _Item(3, 1),
      const _Item(2, 2),
      const _Item(2, 3),
      const _Item(1, 4),
    ];

    final sorted = sorter.sort(
      items,
      [_column()],
      (columnId: 'value', descending: true),
      limit: 3,
      newestKey: (item) => item.newest,
    );

    expect(sorted.map((item) => item.value), [3, 2, 2]);
    expect(sorted.map((item) => item.newest), [1, 3, 2]);
  });
}
