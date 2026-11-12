@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

void main() {
  test(
    'folds a traffic sample into the connection table within the budget',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(connectionsProvider.notifier);
      final start = DateTime.utc(2026);
      final rows = [
        for (var index = 0; index < 500; index++)
          TrackerInfo(
            id: 'connection-$index',
            upload: 1000,
            download: 2000,
            start: start.add(Duration(milliseconds: index)),
            metadata: const Metadata(network: 'tcp', host: 'example.test'),
            chains: const ['DIRECT'],
            rule: 'MATCH',
            rulePayload: '',
          ),
      ];
      notifier.useReader(({bool resync = false}) async {
        return ConnectionDelta(
          added: rows,
          removed: const [],
          count: rows.length,
        );
      });
      await notifier.refresh();
      expect(notifier.state.connections.length, rows.length);

      // A steady table moves a handful of rows at a time, the rest holds.
      final traffic = {
        for (var index = 0; index < 8; index++)
          'connection-$index': (upload: 1000 + index, download: 2000),
        for (var index = 0; index < 40; index++)
          'missing-$index': (upload: 1, download: 1),
      };

      notifier.updateTraffic(traffic);
      final stopwatch = Stopwatch()..start();
      for (var attempt = 0; attempt < 5000; attempt++) {
        notifier.updateTraffic(traffic);
      }
      stopwatch.stop();
      final perBatchUs = stopwatch.elapsedMicroseconds / 5000;
      stdout.writeln(
        'connections.updateTraffic rows=500 moved=8 batches=5000 '
        'perBatchUs=$perBatchUs',
      );
      expect(perBatchUs, lessThan(1000));
    },
  );
}
