@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/fixed.dart';
import 'package:flutter_test/flutter_test.dart';

class _Item {
  const _Item(this.key);

  final String key;
}

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

  test('appends bounded keyed batches within the budget', () {
    const batches = 20000;
    const batchSize = 120;
    const maxLength = 1600;
    final list = FixedList<_Item>(maxLength, keyOf: (item) => item.key);
    final batch = List<_Item>.generate(
      batchSize,
      (index) => _Item('item-$index'),
    );

    // Warm the growable list and the key index before timing.
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
      'FixedList.appendAll keyed batchSize=$batchSize maxLength=$maxLength '
      'batches=$batches perBatchUs=$perBatchUs',
    );
    expect(perBatchUs, lessThan(1000));
  });
}
