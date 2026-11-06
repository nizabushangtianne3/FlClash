@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('renders a stable rule raw value within the budget', () {
    const count = 100000;
    const rule = Rule(
      id: 1,
      ruleAction: RuleAction.DOMAIN_SUFFIX,
      content: 'example.com',
      ruleTarget: 'DIRECT',
      noResolve: true,
    );
    var length = 0;
    expect(rule.rawValue, contains('DOMAIN-SUFFIX'));

    final stopwatch = Stopwatch()..start();
    for (var index = 0; index < count; index++) {
      length += rule.rawValue.length;
    }
    stopwatch.stop();
    stdout.writeln(
      'ruleRawValue count=$count totalUs=${stopwatch.elapsedMicroseconds} '
      'length=$length',
    );
    expect(length, greaterThan(0));
  });
}
