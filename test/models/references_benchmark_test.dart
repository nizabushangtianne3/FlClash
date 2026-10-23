@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads one hundred thousand proxy DNS servers within the budget', () {
    const count = 100000;
    final values = List.generate(
      count,
      (index) => 'ts://proxy-$index.example.com/path#dialer-$index',
    );
    var outputLength = 0;
    final stopwatch = Stopwatch()..start();
    for (final value in values) {
      outputLength += dnsServerProxies(value).length;
    }
    stopwatch.stop();
    stdout.writeln(
      'dnsProxies count=$count totalUs=${stopwatch.elapsedMicroseconds} '
      'perCallUs=${stopwatch.elapsedMicroseconds / count}',
    );
    expect(outputLength, count * 2);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 75)));
  });
}
