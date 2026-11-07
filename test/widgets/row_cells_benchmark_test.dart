@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

TrackerInfo _row(int index) => TrackerInfo(
  id: '$index',
  upload: index,
  download: index * 3,
  start: DateTime.utc(2026).subtract(Duration(seconds: 90 + index)),
  metadata: Metadata(
    network: 'tcp',
    host: 'host-$index.test',
    destinationIP: '1.2.3.4',
    destinationPort: '443',
    process: 'com.android.chrome',
    uid: 10123,
  ),
  chains: const ['Proxy', 'DIRECT'],
  rule: 'DOMAIN-SUFFIX',
  rulePayload: 'example-$index.com',
);

void main() {
  testWidgets('building the cells of a live table row within the budget', (
    tester,
  ) async {
    const count = 500;
    const attempts = 500;
    final rows = [for (var index = 0; index < count; index++) _row(index)];
    RecordTable<TrackerInfo>? table;
    BuildContext? cellContext;

    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        child: SizedBox(
          width: 1200,
          child: RecordTableFrame<TrackerInfo>(
            tableId: 'test',
            items: rows,
            columnsOf: (width) =>
                _columns(cellContext ??= tester.element(find.byType(SizedBox)), width),
            builder: (context, built, items) {
              table = built;
              cellContext ??= context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final record = table!;
    final context = cellContext!;

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final row in rows) {
        record.cellsOf(context, row.copyWith(upload: attempt));
      }
    }
    stopwatch.stop();
    final totalUs = stopwatch.elapsedMicroseconds / attempts;
    stdout.writeln(
      'rowCells rows=$count attempts=$attempts '
      'perRowUs=${totalUs * 1000 / count} totalUs=$totalUs',
    );
  });
}

List<RecordColumn<TrackerInfo>> _columns(BuildContext context, double width) =>
    trackerInfoColumns(context, width: width, isLive: true);
