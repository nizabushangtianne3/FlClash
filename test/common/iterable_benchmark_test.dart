@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chunks one hundred thousand list items within the budget', () {
    const count = 100000;
    final values = List<int>.generate(count, (index) => index);
    var chunks = 0;
    var output = 0;
    final stopwatch = Stopwatch()..start();
    for (final chunk in values.chunks(3)) {
      chunks++;
      output += chunk.length;
    }
    stopwatch.stop();
    stdout.writeln(
      'chunks count=$count totalUs=${stopwatch.elapsedMicroseconds} '
      'perItemUs=${stopwatch.elapsedMicroseconds / count}',
    );
    expect(chunks, (count + 2) ~/ 3);
    expect(output, count);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 8)));
  });
}
