@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final columns = <RecordColumn<int>>[
    RecordColumn(
      const TableColumn('id', 'id', width: 100),
      cell: (_, _) => const SizedBox(),
      sortKey: (item) => item,
    ),
  ];

  test('sorting an already ordered table within the budget', () {
    const count = 10000;
    const attempts = 1000;
    const sort = (columnId: 'id', descending: false);
    final items = List<int>.generate(count, (index) => index);
    final sorter = RecordSorter<int>();

    sorter.sort(items, columns, sort);
    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final next = sorter.sort(List.of(items), columns, sort);
      if (next.length != count) {
        fail('lost table rows');
      }
    }
    stopwatch.stop();
    stdout.writeln(
      'recordSorterOrdered count=$count attempts=$attempts '
      'totalUs=${stopwatch.elapsedMicroseconds}',
    );
  });

  test('sorting a reversed unsorted table within the budget', () {
    const count = 10000;
    const attempts = 1000;
    final items = List<int>.generate(count, (index) => (index * 7919) % count);
    final sorter = RecordSorter<int>();

    sorter.sort(items, columns, (columnId: 'id', descending: false));
    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final sorted = sorter.sort(List.of(items), columns, (
        columnId: 'id',
        descending: false,
      ), reverse: true);
      if (sorted.length != count) {
        fail('lost table rows');
      }
    }
    stopwatch.stop();
    stdout.writeln(
      'recordSorterReversed count=$count attempts=$attempts '
      'totalUs=${stopwatch.elapsedMicroseconds}',
    );
  });
}
