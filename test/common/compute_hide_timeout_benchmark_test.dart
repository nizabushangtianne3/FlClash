@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hiding timed-out proxies over a healthy group stays cheap', () {
    const count = 2000;
    const attempts = 100;
    const testUrl = 'http://delay.test';
    final all = [
      for (var index = 0; index < count; index++)
        Proxy(name: 'proxy-$index', type: 'ss'),
    ];
    final groups = [
      Group(
        name: 'selector',
        type: GroupType.Selector,
        now: 'proxy-${count - 1}',
        all: all,
      ),
    ];
    final delayMap = <String, Map<String, int?>>{
      testUrl: {for (final proxy in all) proxy.name: 100},
    };

    for (var i = 0; i < 50; i++) {
      computeHideTimeout(
        groups: groups,
        allGroups: groups,
        delayMap: delayMap,
        selectedMap: const {'selector': 'last'},
        defaultTestUrl: testUrl,
      );
    }

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final visible = computeHideTimeout(
        groups: groups,
        allGroups: groups,
        delayMap: delayMap,
        selectedMap: const {'selector': 'last'},
        defaultTestUrl: testUrl,
      );
      if (visible.length != 1) {
        fail('lost a group');
      }
    }
    stopwatch.stop();
    stdout.writeln(
      'computeHideTimeoutHealthy count=$count attempts=$attempts '
      'totalUs=${stopwatch.elapsedMicroseconds}',
    );
  });

  test('hiding timed-out proxies over many groups stays cheap', () {
    const groups = 100;
    const perGroup = 20;
    const attempts = 100;
    const testUrl = 'http://delay.test';
    final all = [
      for (var group = 0; group < groups; group++)
        Group(
          name: 'group-$group',
          type: GroupType.Selector,
          testUrl: 'http://group-$group.test',
          all: [
            for (var index = 0; index < perGroup; index++)
              Proxy(name: 'proxy-$group-$index', type: 'ss'),
          ],
        ),
    ];
    final delayMap = <String, Map<String, int?>>{
      for (final group in all)
        group.testUrl!: {for (final proxy in group.all) proxy.name: 100},
    };

    for (var i = 0; i < 50; i++) {
      computeHideTimeout(
        groups: all,
        allGroups: all,
        delayMap: delayMap,
        selectedMap: const {},
        defaultTestUrl: testUrl,
      );
    }

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final visible = computeHideTimeout(
        groups: all,
        allGroups: all,
        delayMap: delayMap,
        selectedMap: const {},
        defaultTestUrl: testUrl,
      );
      if (visible.length != groups) {
        fail('lost a group');
      }
    }
    stopwatch.stop();
    stdout.writeln(
      'computeHideTimeoutGroups groups=$groups perGroup=$perGroup '
      'attempts=$attempts totalUs=${stopwatch.elapsedMicroseconds}',
    );
  });
}
