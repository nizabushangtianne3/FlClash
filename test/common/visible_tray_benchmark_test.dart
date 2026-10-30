@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/compute.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tray proxy selection scans a large group within budget', () {
    const proxies = 5000;
    const batches = 20000;
    final all = [
      for (var index = 0; index < proxies; index++)
        Proxy(name: 'proxy-$index', type: 'ss'),
    ];
    final group = Group(name: 'group', type: GroupType.Selector, all: all);

    final stopwatch = Stopwatch()..start();
    for (var batch = 0; batch < batches; batch++) {
      final visible = visibleTrayProxies(group, 'proxy-${proxies - 1}');
      if (visible.isEmpty) fail('empty tray');
    }
    stopwatch.stop();
    final perCallUs = stopwatch.elapsedMicroseconds ~/ batches;
    stdout.writeln(
      'visibleTrayProxies proxies=$proxies batches=$batches perCallUs=$perCallUs',
    );
    expect(perCallUs, lessThan(1000));
  });
}
