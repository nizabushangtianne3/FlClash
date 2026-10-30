@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compares 500 connection snapshots within the budget', () {
    const count = 500;
    const comparisons = 200000;
    final start = DateTime.utc(2026);
    List<TrackerInfo> rows() => [
      for (var index = 0; index < count; index++)
        TrackerInfo(
          id: 'connection-$index',
          upload: index,
          download: index * 3,
          start: start.add(Duration(milliseconds: index)),
          metadata: const Metadata(network: 'tcp', host: 'example.com'),
          chains: const ['DIRECT'],
          rule: 'MATCH',
          rulePayload: '',
        ),
    ];
    final firstRows = rows();
    final secondRows = [
      for (var index = 0; index < count; index++)
        index < 100
            ? firstRows[index].copyWith(
                upload: index + 1,
                download: index * 3 + 1,
              )
            : firstRows[index],
    ];
    final first = ConnectionsSnapshot(
      count: count,
      connections: firstRows,
      revision: 1,
    );
    final second = ConnectionsSnapshot(
      count: count,
      connections: secondRows,
      revision: 2,
    );

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < comparisons; attempt++) {
      if (first == second) {
        fail('changed snapshots compared equal');
      }
    }
    stopwatch.stop();
    final perComparisonUs = (stopwatch.elapsedMicroseconds * 1000 / comparisons)
        .round();
    stdout.writeln(
      'ConnectionsSnapshot== count=$count comparisons=$comparisons '
      'perComparisonUs=$perComparisonUs',
    );
    expect(perComparisonUs, lessThan(1000));
  });
}
