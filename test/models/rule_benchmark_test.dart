@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('validates one hundred thousand port ranges within the budget', () {
    const count = 100000;
    const rule = Rule(
      id: 1,
      ruleAction: RuleAction.DST_PORT,
      content: '80-90',
      ruleTarget: 'DIRECT',
    );
    var invalid = 0;
    final stopwatch = Stopwatch()..start();
    for (var index = 0; index < count; index++) {
      if (rule.payloadError != null) {
        invalid++;
      }
    }
    stopwatch.stop();
    stdout.writeln(
      'ranges count=$count totalUs=${stopwatch.elapsedMicroseconds} '
      'perCallUs=${stopwatch.elapsedMicroseconds / count}',
    );
    expect(invalid, 0);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 50)));
  });
}
