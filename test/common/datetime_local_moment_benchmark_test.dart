@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shape this replaces: every read casts the moment to the local zone
/// again and renders it from scratch.
String _replacedShowTime(DateTime time) {
  final local = time.isUtc ? time.toLocal() : time;
  return ' ${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}:'
      '${local.second.toString().padLeft(2, '0')}';
}

void main() {
  test('reading a table row time within the budget', () {
    const count = 500;
    const attempts = 2000;
    final items = [
      for (var index = 0; index < count; index++)
        DateTime.utc(2026, 1, 1).add(Duration(milliseconds: index)),
    ];

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final item in items) {
        _replacedShowTime(item);
      }
    }
    stopwatch.stop();
    final replacedUs = stopwatch.elapsedMicroseconds / attempts;

    stopwatch.reset();
    stopwatch.start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final item in items) {
        item.showTime;
      }
    }
    stopwatch.stop();
    final landedUs = stopwatch.elapsedMicroseconds / attempts;

    stdout.writeln(
      'rowShowTime rows=$count attempts=$attempts '
      'replacedUs=$replacedUs landedUs=$landedUs',
    );
  });
}
