@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats date and time slices within the budget', () {
    const count = 1000000;
    final local = DateTime(2026, 11, 7, 4, 30, 1);
    final utc = DateTime.utc(2026, 11, 7, 4, 30, 1);
    var length = 0;

    final stopwatch = Stopwatch()..start();
    for (var index = 0; index < count; index++) {
      length += local.show.length;
      length += local.showTime.length;
      length += utc.show.length;
      length += utc.showTime.length;
    }
    stopwatch.stop();

    stdout.writeln(
      'showSlices count=$count totalUs=${stopwatch.elapsedMicroseconds} '
      'length=$length',
    );
    expect(length, greaterThan(0));
  });
}
