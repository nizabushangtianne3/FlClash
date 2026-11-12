@Skip('Manual performance benchmark')
import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('takes a feed snapshot within the budget', () {
    const rows = 1600;
    const snapshots = 20000;
    final items = [
      for (var index = 0; index < rows; index++)
        TrackerInfo(
          id: 'request-$index',
          upload: index,
          download: index * 2,
          start: DateTime.utc(2026),
          metadata: const Metadata(network: 'tcp', host: 'example.test'),
          chains: const ['DIRECT'],
          rule: 'MATCH',
          rulePayload: '',
        ),
    ];

    var whole = 0;
    final wholeWatch = Stopwatch()..start();
    for (var attempt = 0; attempt < snapshots; attempt++) {
      final reversed = items.reversed.toList();
      whole += reversed.length;
    }
    wholeWatch.stop();

    var head = 0;
    final headWatch = Stopwatch()..start();
    for (var attempt = 0; attempt < snapshots; attempt++) {
      final bounded = items.reversed.take(100).toList();
      head += bounded.length;
    }
    headWatch.stop();

    final wholeUs = wholeWatch.elapsedMicroseconds / snapshots;
    final headUs = headWatch.elapsedMicroseconds / snapshots;
    if (whole != snapshots * rows || head != snapshots * 100) {
      fail('wrong sizes');
    }
    stdout.writeln(
      'feedSnapshot rows=$rows snapshots=$snapshots '
      'wholeReversedUs=$wholeUs boundedHeadUs=$headUs',
    );
  });
}
