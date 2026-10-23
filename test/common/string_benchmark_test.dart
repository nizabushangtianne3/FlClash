@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('splits one hundred thousand server lists within the budget', () {
    const count = 100000;
    final values = List.generate(
      count,
      (index) => 'server-$index, backup-$index; direct-$index',
    );
    var outputLength = 0;
    final stopwatch = Stopwatch()..start();
    for (final value in values) {
      final result = value.splitByMultipleSeparators;
      outputLength += result is List<String>
          ? result.length
          : (result as String).length;
    }
    stopwatch.stop();
    stdout.writeln(
      'split count=$count totalUs=${stopwatch.elapsedMicroseconds} '
      'perCallUs=${stopwatch.elapsedMicroseconds / count}',
    );
    expect(outputLength, greaterThan(0));
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 50)));
  });
}
