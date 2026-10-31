@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/fixed.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

void main() {
  test('updates 100 traffic samples over 500 requests within the budget', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(requestsProvider.notifier);
    notifier.value = FixedList(1000, keyOf: (request) => request.id);
    final start = DateTime.utc(2026);
    for (var index = 0; index < 500; index++) {
      notifier.addRequest(
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
      );
    }
    final traffic = {
      for (var index = 0; index < 100; index++)
        'connection-$index': (upload: index + 1, download: index * 2),
      for (var index = 500; index < 600; index++)
        'missing-$index': (upload: 1, download: 2),
    };

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < 5000; attempt++) {
      notifier.updateTraffic(traffic);
    }
    stopwatch.stop();
    final perBatchUs = stopwatch.elapsedMicroseconds ~/ 5000;
    stdout.writeln(
      'requests.updateTraffic requests=500 updates=100 '
      'batches=5000 perBatchUs=$perBatchUs',
    );
    expect(perBatchUs, lessThan(1000));
  });
}
