@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

TrackerInfo _connection(int index, {int download = 0, int upload = 0}) =>
    TrackerInfo(
      id: 'c-$index',
      upload: upload,
      download: download,
      start: DateTime.utc(2026).add(Duration(milliseconds: index)),
      metadata: Metadata(
        network: index.isEven ? 'tcp' : 'udp',
        host: 'host-$index.test',
        destinationPort: '443',
        destinationIP: '198.18.0.${index % 256}',
        process: 'com.android.chrome',
        processPath: '/system/bin/chrome',
      ),
      chains: const ['Proxy', 'DIRECT'],
      rule: 'DOMAIN-SUFFIX',
      rulePayload: 'example-$index.com',
    );

void main() {
  testWidgets('stages of one connection poll', (tester) async {
    late RecordTable<TrackerInfo>? table;
    late BuildContext cellContext;
    BuildContext? shell;

    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        child: Builder(
          builder: (context) {
            shell = context;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    final shellContext = shell!;

    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        child: Builder(
          builder: (inner) => SizedBox(
            width: 1200,
            child: RecordTableFrame<TrackerInfo>(
              tableId: 'probe',
              items: const <TrackerInfo>[],
              columnsOf: (width) =>
                  trackerInfoColumns(inner, width: width, isLive: true),
              builder: (context, built, items) {
                table = built;
                cellContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final record = table!;
    final buildContext = cellContext;
    final columns = trackerInfoColumns(shellContext, width: 1200, isLive: true);

    const count = 1000;
    final ranker = TrackerSpeedRanker();
    final listController = TrackerInfoListController();
    final filters = RecordFilterController<TrackerInfo>(
      facets: trackerInfoFacets,
    );
    final sorter = RecordSorter<TrackerInfo>();

    final rows = [
      for (var index = 0; index < count; index++)
        _connection(
          index,
          download: index % 20 == 0 ? 4096 : 0,
          upload: index % 20 == 1 ? 2048 : 0,
        ),
    ];

    // Warm each stage before it is timed: the first call is the JIT compiling
    // it. The median of a few runs is what a poll costs.
    void timed(String name, void Function() run) {
      for (var warmup = 0; warmup < 5; warmup++) {
        run();
      }
      final runs = <int>[];
      for (var attempt = 0; attempt < 9; attempt++) {
        final sw = Stopwatch()..start();
        run();
        sw.stop();
        runs.add(sw.elapsedMicroseconds);
      }
      runs.sort();
      stdout.writeln('$name: ${runs[4]}us (min ${runs.first})');
    }

    final readAt = DateTime.now();
    final ranked = ranker.rank(rows, readAt);
    timed('rank', () => ranker.rank(rows, readAt));
    timed('setTrackerInfos', () => listController.setTrackerInfos(ranked));
    timed('offer', () => filters.offer(ranked));
    final applied = filters.apply(ranked);
    timed('apply', () => filters.apply(ranked));
    timed('sort', () => sorter.sort(applied, columns, null));
    final visible = sorter.sort(applied, columns, null).take(20).toList();
    timed('cellsOf x20', () {
      for (final item in visible) {
        record.cellsOf(buildContext, item);
      }
    });
  });
}
