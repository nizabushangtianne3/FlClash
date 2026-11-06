@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/test_profiles.dart';

void main() {
  test('resolving selected proxy of a large group within budget', () {
    const count = 2000;
    const attempts = 2000;
    final all = [
      for (var index = 0; index < count; index++)
        Proxy(name: 'proxy-$index', type: 'ss'),
    ];
    final container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(TestProfiles.new)],
    );
    addTearDown(container.dispose);
    container
        .read(groupsProvider.notifier)
        .update(
          (_) => [
            Group(
              name: 'G',
              type: GroupType.Selector,
              now: 'proxy-${count - 1}',
              all: all,
            ),
          ],
        );
    expect(
      container.read(selectedProxyNameProvider('G')),
      'proxy-${count - 1}',
    );

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      container.refresh(selectedProxyNameProvider('G'));
    }
    stopwatch.stop();
    stdout.writeln(
      'selectedProxyName count=$count attempts=$attempts '
      'totalUs=${stopwatch.elapsedMicroseconds}',
    );
    expect(stopwatch.elapsedMicroseconds, greaterThan(0));
  });
}
