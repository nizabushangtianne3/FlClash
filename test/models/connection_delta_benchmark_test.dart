@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _connection(int index) {
  return {
    'id': 'connection-$index',
    'upload': index,
    'download': index * 3,
    'start': '2026-09-18T04:30:01Z',
    'metadata': {
      'network': 'tcp',
      'host': 'example-$index.com',
      'destinationIP': '1.2.3.$index',
      'destinationPort': '443',
      'sourceIP': '192.168.1.2',
      'sourcePort': '${5000 + index}',
    },
    'chains': ['DIRECT'],
    'rule': 'MATCH',
    'rulePayload': '',
  };
}

void main() {
  test('parses bounded connection deltas within the budget', () {
    const batches = 2000;
    const rows = 300;
    final data = {
      'added': List<Map<String, Object?>>.generate(rows, _connection),
      'removed': List<String>.generate(rows, (index) => 'old-$index'),
      'count': rows,
    };

    final stopwatch = Stopwatch()..start();
    for (var batchIndex = 0; batchIndex < batches; batchIndex++) {
      final delta = connectionDeltaOf(data);
      if (delta.added.length != rows ||
          delta.removed.length != rows ||
          delta.count != rows) {
        fail('short connection delta');
      }
    }
    stopwatch.stop();
    final perBatchUs = stopwatch.elapsedMicroseconds ~/ batches;
    stdout.writeln(
      'connectionDeltaOf rows=$rows batches=$batches perBatchUs=$perBatchUs',
    );
    expect(perBatchUs, lessThan(10000));
  });
}
