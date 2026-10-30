@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

TrackerInfo _connection(int index) {
  final start = DateTime.utc(2026);
  return TrackerInfo(
    id: 'connection-$index',
    upload: index,
    download: index * 3,
    start: start.add(Duration(milliseconds: index)),
    metadata: const Metadata(network: 'tcp', host: 'example.com'),
    chains: const ['DIRECT'],
    rule: 'MATCH',
    rulePayload: '',
  );
}

void main() {
  test('merges unchanged connection polls within the budget', () async {
    const rows = 300;
    const polls = 5000;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(connectionsProvider.notifier);
    final full = ConnectionDelta(
      added: List<TrackerInfo>.generate(rows, _connection),
      count: rows,
    );
    const unchanged = ConnectionDelta(count: rows);
    var first = true;
    notifier.useReader(({resync = false}) async {
      if (first) {
        first = false;
        return full;
      }
      return unchanged;
    });

    await notifier.refresh();
    final stopwatch = Stopwatch()..start();
    for (var index = 0; index < polls; index++) {
      await notifier.refresh();
    }
    stopwatch.stop();
    final perPollUs = stopwatch.elapsedMicroseconds ~/ polls;
    stdout.writeln(
      'connections.refresh rows=$rows polls=$polls perPollUs=$perPollUs',
    );
    expect(container.read(connectionsProvider).count, rows);
    expect(perPollUs, lessThan(1000));
  });
}
