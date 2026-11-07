import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

List<RecordColumn<int>> _columns(Comparable<Object> Function(int item) key) {
  return [
    RecordColumn(
      const TableColumn('id', 'id', width: 100),
      cell: (_, _) => const SizedBox(),
      sortKey: key,
    ),
    RecordColumn(
      const TableColumn('name', 'name', flex: 2),
      cell: (_, _) => const SizedBox(),
      sortKey: key,
    ),
    RecordColumn(
      const TableColumn('extra', 'extra', flex: 1),
      cell: (_, _) => const SizedBox(),
      sortKey: key,
    ),
  ];
}

void main() {
  group('recordTableColumns', () {
    test('hands the rows their layouts and their widths', () {
      final table = recordTableColumns(
        columnsOf: (width) => _columns((item) => item),
        availableWidth: 400,
        columnWidths: const {},
      );

      expect(table.layouts, [
        for (final column in table.columns) column.layout,
      ]);
      expect(table.columns, hasLength(3));
      expect(table.widths, hasLength(3));
      expect(table.widths.first, 100);
      // The flex column takes what the fixed one leaves.
      expect(table.widths[1], closeTo(200, 0.001));
      expect(table.widths.last, closeTo(100, 0.001));
      expect(table.widths.reduce((a, b) => a + b), closeTo(400, 0.001));
    });

    test('a dragged width wins over the column own', () {
      final table = recordTableColumns(
        columnsOf: (width) => _columns((item) => item),
        availableWidth: 400,
        columnWidths: const {'name': 250},
      );

      expect(table.widths.first, 100);
      expect(table.widths[1], 250);
      expect(table.layouts, hasLength(3));
    });
  });

  group('RecordSorter', () {
    test('keeps the source list when it is already ordered', () {
      final items = List<int>.generate(100, (index) => index);
      final sorter = RecordSorter<int>();
      sorter.sort(items, _columns((item) => item), (
        columnId: 'id',
        descending: false,
      ));
      final next = List.of(items);

      final sorted = sorter.sort(next, _columns((item) => item), (
        columnId: 'id',
        descending: false,
      ));
      expect(identical(sorted, next), isTrue);
      expect(sorted, items);
    });

    test('sorts ascending and descending while ties stay put', () {
      final items = <int>[3, 1, 1, 2];
      final sorter = RecordSorter<int>();

      final asc = sorter.sort(items, _columns((item) => item), (
        columnId: 'id',
        descending: false,
      ));
      expect(asc, [1, 1, 2, 3]);

      final desc = sorter.sort(items, _columns((item) => item), (
        columnId: 'id',
        descending: true,
      ));
      expect(desc, [3, 2, 1, 1]);
    });

    test('a reversed already ordered list keeps its source order', () {
      final items = List<int>.generate(10, (index) => index);
      final sorter = RecordSorter<int>();

      final sorted = sorter.sort(List.of(items), _columns((item) => item), (
        columnId: 'id',
        descending: true,
      ), reverse: true);
      expect(sorted, items);
    });

    test('a reversed unsorted list sorts its source list the other way', () {
      final items = <int>[3, 1, 2];
      final sorter = RecordSorter<int>();

      final asc = sorter.sort(items, _columns((item) => item), (
        columnId: 'id',
        descending: false,
      ), reverse: true);
      expect(asc, [3, 2, 1]);

      final desc = sorter.sort(items, _columns((item) => item), (
        columnId: 'id',
        descending: true,
      ), reverse: true);
      expect(desc, [1, 2, 3]);
    });
  });
}
