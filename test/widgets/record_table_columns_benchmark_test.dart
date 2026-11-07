@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A card table's column set, shaped like the dashboard's own: every column
/// carries a cell, a sort key and a fixed width or a flex.
List<RecordColumn<int>> _columns(
  AppLocalizations appLocalizations,
  double width,
) {
  final wide = width >= 1000;
  return [
    RecordColumn(
      TableColumn('time', appLocalizations.time, width: 76),
      cell: (_, _) => const SizedBox(),
      sortKey: (item) => item,
      descendingFirst: true,
    ),
    RecordColumn(
      TableColumn('source', appLocalizations.source, width: wide ? 160 : 140),
      cell: (_, _) => const SizedBox(),
      sortKey: (item) => item,
    ),
    RecordColumn(
      TableColumn('target', appLocalizations.target, flex: wide ? 1.3 : 1),
      cell: (_, _) => const SizedBox(),
      sortKey: (item) => item,
    ),
    if (wide)
      RecordColumn(
        TableColumn('protocol', appLocalizations.protocol, width: 52),
        cell: (_, _) => const SizedBox(),
        sortKey: (item) => item,
      ),
    RecordColumn(
      TableColumn('rule', appLocalizations.rule, flex: 1),
      cell: (_, _) => const SizedBox(),
      sortKey: (item) => item,
    ),
    RecordColumn(
      TableColumn('exit', appLocalizations.outboundExit, width: 120),
      cell: (_, _) => const SizedBox(),
      sortKey: (item) => item,
    ),
    RecordColumn(
      TableColumn('download', appLocalizations.download, width: 80, end: true),
      cell: (_, _) => const SizedBox(),
      sortKey: (item) => item,
      descendingFirst: true,
    ),
    RecordColumn(
      TableColumn('upload', appLocalizations.upload, width: 80, end: true),
      cell: (_, _) => const SizedBox(),
      sortKey: (item) => item,
      descendingFirst: true,
    ),
  ];
}

void main() {
  test('building a card table columns within the budget', () async {
    const width = 1000.0;
    const attempts = 20000;
    final appLocalizations = await AppLocalizations.load(const Locale('en'));
    const columnWidths = <String, double>{};
    const locale = Locale('en');
    const nextInputs = (1000.0, <String, double>{}, locale);
    ({
      List<RecordColumn<int>> columns,
      List<TableColumn> layouts,
      List<double> widths,
    })?
    memo;
    Object? memoInputs;

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final (:columns, :layouts, :widths) = recordTableColumns(
        columnsOf: (width) => _columns(appLocalizations, width),
        availableWidth: width,
        columnWidths: columnWidths,
      );
      if (columns.length != widths.length || columns.length != layouts.length) {
        fail('lost table columns');
      }
      memo = (columns: columns, layouts: layouts, widths: widths);
      memoInputs ??= nextInputs;
    }
    stopwatch.stop();
    final rebuiltUs = stopwatch.elapsedMicroseconds / attempts;

    stopwatch.reset();
    stopwatch.start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final current = nextInputs == memoInputs ? memo : null;
      if (current == null || current.columns.length != current.widths.length) {
        fail('lost the memoized table');
      }
    }
    stopwatch.stop();
    final memoizedUs = stopwatch.elapsedMicroseconds / attempts;

    stdout.writeln(
      'recordTableColumns width=$width attempts=$attempts '
      'rebuiltUs=$rebuiltUs memoizedUs=$memoizedUs',
    );
  });
}
