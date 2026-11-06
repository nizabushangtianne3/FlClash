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
  ];
}

void main() {
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
  });
}
