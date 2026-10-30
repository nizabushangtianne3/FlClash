@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses bounded event batches within the budget', () {
    const batches = 10000;
    const batchSize = 300;
    final batch = List<Map<String, Object?>>.generate(batchSize, (index) {
      return {
        'type': index.isEven ? 'log' : 'loaded',
        'data': index.isEven
            ? {'LogLevel': 'info', 'Payload': 'event-$index'}
            : 'provider-$index',
      };
    });

    final stopwatch = Stopwatch()..start();
    for (var batchIndex = 0; batchIndex < batches; batchIndex++) {
      final events = coreEventsFromData(batch);
      if (events.length != batchSize) {
        fail('short event batch');
      }
      if (events.last.type != CoreEventType.loaded) {
        fail('unexpected event type');
      }
    }
    stopwatch.stop();
    final perBatchUs = stopwatch.elapsedMicroseconds ~/ batches;
    stdout.writeln(
      'coreEventsFromData batchSize=$batchSize batches=$batches '
      'perBatchUs=$perBatchUs',
    );
    expect(perBatchUs, lessThan(2000));
  });
}
