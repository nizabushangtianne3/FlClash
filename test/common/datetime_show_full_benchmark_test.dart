@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats a full timestamp within the budget', () {
    const count = 1000000;
    final date = DateTime.utc(2026, 11, 7, 4, 30, 1);
    var length = 0;

    final stopwatch = Stopwatch()..start();
    for (var index = 0; index < count; index++) {
      length += date.showFull.length;
    }
    stopwatch.stop();

    stdout.writeln(
      'showFull count=$count totalUs=${stopwatch.elapsedMicroseconds} '
      'length=$length',
    );
  });
}
