@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/views/dashboard/style.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('counting a dashboard figure costs what intl asks for it', () {
    const counts = [0, 7, 42, 99, 512, 1024, 99999, 65535, 1000000];
    const attempts = 20000;
    dashboardCount(1024);
    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final count in counts) {
        dashboardCount(count);
      }
    }
    stopwatch.stop();
    final perCountNs =
        stopwatch.elapsedMicroseconds * 1000 / attempts / counts.length;
    stdout.writeln(
      'dashboardCount values=${counts.length} attempts=$attempts '
      'perCountNs=$perCountNs',
    );
  });
}
