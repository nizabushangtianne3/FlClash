@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/num.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats one hundred thousand traffic values within the budget', () {
    const count = 100000;
    final values = List<num>.generate(count, (index) => (index % 4096) + 0.25);
    var outputLength = 0;
    final stopwatch = Stopwatch()..start();
    for (final value in values) {
      outputLength += value.fixed(decimals: 1).length;
    }
    stopwatch.stop();
    stdout.writeln(
      'fixed count=$count totalUs=${stopwatch.elapsedMicroseconds} '
      'perCallUs=${stopwatch.elapsedMicroseconds / count}',
    );
    expect(outputLength, greaterThan(0));
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 40)));
  });
}
