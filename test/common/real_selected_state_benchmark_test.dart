@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolving a table of leaf proxies within the budget', () {
    const count = 1000;
    const attempts = 500;
    final proxies = [
      for (var index = 0; index < count; index++)
        Proxy(name: 'proxy-$index', type: 'ss'),
    ];
    final groups = [Group(type: GroupType.Selector, name: 'G', all: proxies)];
    final groupsByName = groupsByNameFor(groups);
    const selectedMap = <String, String>{};

    for (var warm = 0; warm < 50; warm++) {
      for (final proxy in proxies) {
        computeRealSelectedProxyState(
          proxy.name,
          groups: groups,
          groupsByName: groupsByName,
          selectedMap: selectedMap,
        );
        if (groupsByName[proxy.name] != null) {
          continue;
        }
      }
    }

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final proxy in proxies) {
        computeRealSelectedProxyState(
          proxy.name,
          groups: groups,
          groupsByName: groupsByName,
          selectedMap: selectedMap,
        );
      }
    }
    stopwatch.stop();
    final resolvedUs = stopwatch.elapsedMicroseconds / attempts;

    stopwatch.reset();
    stopwatch.start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final proxy in proxies) {
        if (groupsByName[proxy.name] != null) {
          continue;
        }
      }
    }
    stopwatch.stop();
    final leafUs = stopwatch.elapsedMicroseconds / attempts;

    stdout.writeln(
      'realSelectedState count=$count attempts=$attempts '
      'resolvedUs=$resolvedUs leafUs=$leafUs',
    );
  });
}
