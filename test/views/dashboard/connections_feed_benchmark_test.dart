@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/views/dashboard/widgets/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo _connection(int index) {
  return TrackerInfo(
    id: '$index',
    download: index,
    start: DateTime.utc(2026).subtract(Duration(seconds: index)),
    metadata: Metadata(
      network: index.isEven ? 'tcp' : 'UDP',
      host: 'host-$index',
    ),
    chains: const ['Proxy'],
    rule: 'MATCH',
    rulePayload: '',
  );
}

/// The shape this replaces: counting built a lower-case copy of every row.
int _replacedSplit(List<TrackerInfo> rows) {
  final ordered = [...rows]..sort((a, b) => b.start.compareTo(a.start));
  var tcp = 0;
  for (final item in ordered) {
    if (item.metadata.network.toLowerCase() == 'tcp') {
      tcp++;
    }
  }
  return tcp;
}

/// What the feed prepares now: the same ordering, counted without the copy.
int _landedSplit(List<TrackerInfo> rows) {
  final ordered = [...rows]..sort((a, b) => b.start.compareTo(a.start));
  return liveProtocolSplit(ordered).tcp;
}

void main() {
  test(
    'preparing the live feed of a counter-only update within the budget',
    () {
      const count = 300;
      const attempts = 2000;
      final rows = [
        for (var index = 0; index < count; index++) _connection(index),
      ];
      expect(_replacedSplit(rows), _landedSplit(rows));

      final stopwatch = Stopwatch()..start();
      for (var attempt = 0; attempt < attempts; attempt++) {
        _replacedSplit(rows);
      }
      stopwatch.stop();
      final replacedUs = stopwatch.elapsedMicroseconds / attempts;

      stopwatch.reset();
      stopwatch.start();
      for (var attempt = 0; attempt < attempts; attempt++) {
        _landedSplit(rows);
      }
      stopwatch.stop();
      final landedUs = stopwatch.elapsedMicroseconds / attempts;

      stdout.writeln(
        'liveConnectionsFeed rows=$count attempts=$attempts '
        'replacedUs=$replacedUs landedUs=$landedUs',
      );
    },
  );
}
