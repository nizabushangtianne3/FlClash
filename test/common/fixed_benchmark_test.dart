@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/fixed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retains a bounded head without combining large lists', () {
    const count = 500000;
    const limit = 100;
    final current = List<int>.generate(count, (index) => index);
    final latest = List<int>.generate(count, (index) => count + index);

    final stopwatch = Stopwatch()..start();
    final result = retainTrimmedHead(current, latest, limit);
    stopwatch.stop();
    stdout.writeln(
      'retainTrimmedHead count=$count limit=$limit '
      'totalUs=${stopwatch.elapsedMicroseconds}',
    );

    expect(result, hasLength(limit));
    expect(result.first, 0);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1)));
  });
}
