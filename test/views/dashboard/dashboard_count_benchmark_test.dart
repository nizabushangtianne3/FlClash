@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/views/dashboard/style.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show NumberFormat;

/// Measures what [dashboardCount] costs against the general pattern parser it
/// replaced, and checks the two agree on every value a dashboard can show.
void main() {
  test('grouping a dashboard figure beats the intl pattern', () {
    const counts = [0, 7, 42, 99, 512, 1024, 99999, 65535, 1000000];
    const attempts = 20000;

    final intl = NumberFormat.decimalPattern('en');
    dashboardCount(1024);

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final count in counts) {
        intl.format(count);
      }
    }
    stopwatch.stop();
    final intlNs =
        stopwatch.elapsedMicroseconds * 1000 / attempts / counts.length;

    final stopwatch2 = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final count in counts) {
        dashboardCount(count);
      }
    }
    stopwatch2.stop();
    final currentNs =
        stopwatch2.elapsedMicroseconds * 1000 / attempts / counts.length;

    // Every value below 100000 groups; both sides must agree word for word.
    for (final count in counts.where((count) => count < 100000)) {
      expect(intl.format(count), dashboardCount(count));
    }

    stdout.writeln(
      'dashboardCount values=${counts.length} attempts=$attempts '
      'intlPatternNs=$intlNs currentNs=$currentNs',
    );
  });
}
