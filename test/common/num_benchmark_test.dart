@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/num.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('trimming the fixed decimals costs what the VM already charges', () {
    const count = 100000;
    final values = List<num>.generate(count, (index) => (index % 4096) + 0.25);
    var rawSink = 0;
    var fixedSink = 0;

    double rawUs() {
      final stopwatch = Stopwatch()..start();
      for (final value in values) {
        rawSink += value.toStringAsFixed(1).length;
      }
      stopwatch.stop();
      return stopwatch.elapsedMicroseconds / count;
    }

    double fixedUs() {
      final stopwatch = Stopwatch()..start();
      for (final value in values) {
        fixedSink += value.fixed(decimals: 1).length;
      }
      stopwatch.stop();
      return stopwatch.elapsedMicroseconds / count;
    }

    // Warm both paths before the rounds that are compared.
    rawUs();
    fixedUs();

    final raw = <double>[];
    final fixed = <double>[];
    for (var round = 0; round < 3; round++) {
      if (round.isEven) {
        raw.add(rawUs());
        fixed.add(fixedUs());
      } else {
        fixed.add(fixedUs());
        raw.add(rawUs());
      }
    }
    raw.sort();
    fixed.sort();
    final rawMedian = raw[raw.length ~/ 2];
    final fixedMedian = fixed[fixed.length ~/ 2];

    stdout.writeln(
      'fixedVsRaw count=$count rounds=${raw.length} '
      'rawMedianUs=$rawMedian fixedMedianUs=$fixedMedian '
      'deltaUs=${fixedMedian - rawMedian}',
    );
    expect(rawSink, greaterThan(0));
    expect(fixedSink, greaterThan(0));
  });

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
