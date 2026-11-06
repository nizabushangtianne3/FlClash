@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sorting a large delayed group stays within the budget', () {
    const count = 1000;
    const attempts = 100;
    const testUrl = 'http://delay.test';
    final all = [
      for (var index = 0; index < count; index++)
        Proxy(name: 'proxy-$index', type: 'ss'),
    ];
    final groups = [Group(name: 'G', type: GroupType.Selector, all: all)];
    final delayMap = <String, Map<String, int?>>{
      testUrl: {
        for (var index = 0; index < count; index++)
          'proxy-$index': switch (index % 4) {
            0 => 100 + (count - index),
            1 => delayTimedOutValue,
            2 => 0,
            _ => null,
          },
      },
    };

    for (var i = 0; i < 5; i++) {
      computeSort(
        groups: groups,
        sortType: ProxiesSortType.delay,
        delayMap: delayMap,
        selectedMap: const {},
        defaultTestUrl: testUrl,
      );
    }

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final sorted = computeSort(
        groups: groups,
        sortType: ProxiesSortType.delay,
        delayMap: delayMap,
        selectedMap: const {},
        defaultTestUrl: testUrl,
      );
      if (sorted.length != groups.length) {
        fail('lost a group');
      }
    }
    stopwatch.stop();
    stdout.writeln(
      'computeSortDelay count=$count attempts=$attempts '
      'totalUs=${stopwatch.elapsedMicroseconds}',
    );
  });
}
