@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/fixed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appends bounded batches within the budget', () {
    const batches = 20000;
    const batchSize = 300;
    const maxLength = 1000;
    final list = FixedList<int>(maxLength);
    final batch = List<int>.generate(batchSize, (index) => index);

    // Warm the growable list and snapshot paths before timing.
    list.appendAll(batch);
    list.list;
    final stopwatch = Stopwatch()..start();
    for (var batchIndex = 0; batchIndex < batches; batchIndex++) {
      list.appendAll(batch);
      if (batchIndex.isEven) {
        list.list;
      }
    }
    stopwatch.stop();
    final perBatchUs = stopwatch.elapsedMicroseconds ~/ batches;
    stdout.writeln(
      'FixedList.appendAll batchSize=$batchSize maxLength=$maxLength '
      'batches=$batches perBatchUs=$perBatchUs',
    );
    expect(perBatchUs, lessThan(1000));
  });
}
