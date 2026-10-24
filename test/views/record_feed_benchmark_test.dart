@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/widgets/record_table.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sizes the app declares, at the largest the paused lists reach.
const _pausedQueries = 4800;

List<DnsQuery> _queries() => [
  for (var index = 0; index < _pausedQueries; index++)
    DnsQuery(
      domain: 'host-$index.example${index % 7}.com',
      type: 'A',
      upstream: 'udp://223.5.5.5:53',
      answers: ['1.2.3.${index % 256}'],
      delay: index,
      time: DateTime.utc(2026).add(Duration(milliseconds: index)),
    ),
];

void main() {
  test('filters a paused DNS view within the budget', () {
    const keystrokes = 20;
    final queries = _queries();
    final texts = Expando<String>();

    final stopwatch = Stopwatch()..start();
    for (var stroke = 0; stroke < keystrokes; stroke++) {
      final query = SearchQuery('host-${stroke % 9}');
      queries
          .whereMatches(query, (item) => item.searchFields, texts: texts)
          .toList();
    }
    stopwatch.stop();

    final perStroke = stopwatch.elapsedMicroseconds ~/ keystrokes;
    stdout.writeln(
      'dns filter count=$_pausedQueries keystrokes=$keystrokes '
      'totalUs=${stopwatch.elapsedMicroseconds} perStrokeUs=$perStroke',
    );
    expect(perStroke, lessThan(8000));
  });

  test('sorts a paused DNS feed within the budget', () {
    const snapshots = 20;
    final queries = _queries();
    final columns = <RecordColumn<DnsQuery>>[
      RecordColumn(
        const TableColumn('domain', 'Domain', flex: 1),
        cell: (_, _) => const SizedBox.shrink(),
        sortKey: (query) => query.domain,
      ),
    ];
    final sorter = RecordSorter<DnsQuery>();

    final stopwatch = Stopwatch()..start();
    for (var snapshot = 0; snapshot < snapshots; snapshot++) {
      sorter.sort(
        queries,
        columns,
        null,
        limit: 100,
        newestKey: (query) => query.time,
      );
    }
    stopwatch.stop();

    final perSnapshot = stopwatch.elapsedMicroseconds ~/ snapshots;
    stdout.writeln(
      'dns feed sort count=$_pausedQueries snapshots=$snapshots '
      'totalUs=${stopwatch.elapsedMicroseconds} perSnapshotUs=$perSnapshot',
    );
    expect(perSnapshot, lessThan(8000));
  });

  test('filters a paused log view within the budget', () {
    const count = 8000;
    const keystrokes = 20;
    final logs = [
      for (var index = 0; index < count; index++)
        Log(
          logLevel: LogLevel.info,
          payload:
              '[TCP] 10.0.$index --> host$index.example.com:443 match MATCH '
              'using DIRECT with rule set ${index % 97} '
              'from provider ${index % 13}',
          dateTime: DateTime.utc(
            2026,
          ).add(Duration(milliseconds: index)).showFull,
        ),
    ];

    final stopwatch = Stopwatch()..start();
    for (var stroke = 0; stroke < keystrokes; stroke++) {
      LogsState(logs: logs, query: 'provider-${stroke % 13}').list;
    }
    stopwatch.stop();

    final perStroke = stopwatch.elapsedMicroseconds ~/ keystrokes;
    stdout.writeln(
      'log filter count=$count keystrokes=$keystrokes '
      'totalUs=${stopwatch.elapsedMicroseconds} perStrokeUs=$perStroke',
    );
    expect(perStroke, lessThan(8000));
  });
}
