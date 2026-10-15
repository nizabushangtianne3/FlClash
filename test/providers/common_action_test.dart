import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod/riverpod.dart';

class MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

const runningVersion = '0.8.96';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockCoreHandlerInterface core;

  setUpAll(() {
    core = MockCoreHandlerInterface();
    globalState.packageInfo = PackageInfo(
      appName: 'FlClash',
      packageName: 'com.follow.clash',
      version: runningVersion,
      buildNumber: '1',
    );
  });

  setUp(() => reset(core));

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('CommonAction.updateMode', () {
    test('advances through every mode and wraps back to the first', () {
      final container = buildContainer();
      final action = container.read(commonActionProvider.notifier);
      container
          .read(patchClashConfigProvider.notifier)
          .update((state) => state.copyWith(mode: Mode.values.first));

      final seen = <Mode>[container.read(patchClashConfigProvider).mode];
      for (var i = 0; i < Mode.values.length; i++) {
        action.updateMode();
        seen.add(container.read(patchClashConfigProvider).mode);
      }

      expect(seen.sublist(0, Mode.values.length), Mode.values);
      expect(seen.last, Mode.values.first, reason: 'wraps after the last mode');
    });
  });

  group('CommonAction.updateSpeedStatistics', () {
    test('toggles the tray title flag both ways', () {
      final container = buildContainer();
      final action = container.read(commonActionProvider.notifier);
      final initial = container.read(appSettingProvider).showTrayTitle;

      action.updateSpeedStatistics();
      expect(container.read(appSettingProvider).showTrayTitle, !initial);

      action.updateSpeedStatistics();
      expect(container.read(appSettingProvider).showTrayTitle, initial);
    });
  });

  group('CommonAction.updateTraffic', () {
    void connectCore(ProviderContainer container) {
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    }

    test('records the sampled traffic and the running total', () async {
      final container = buildContainer();
      connectCore(container);
      when(() => core.getTrafficStats(true)).thenAnswer(
        (_) async => (
          now: const Traffic(up: 10, down: 20),
          total: const Traffic(up: 100, down: 200),
        ),
      );

      await container.read(commonActionProvider.notifier).updateTraffic();

      expect(container.read(trafficsProvider).list.last.up, 10);
      expect(container.read(trafficsProvider).list.last.down, 20);
      expect(
        container.read(totalTrafficProvider),
        const Traffic(up: 100, down: 200),
      );
      verify(() => core.getTrafficStats(true)).called(1);
    });

    test('swallows a stats failure and leaves the total untouched', () async {
      final container = buildContainer();
      connectCore(container);
      final before = container.read(totalTrafficProvider);
      when(() => core.getTrafficStats(any())).thenThrow(StateError('boom'));

      await expectLater(
        container.read(commonActionProvider.notifier).updateTraffic(),
        completes,
      );
      expect(container.read(totalTrafficProvider), before);
    });

    test('does not record traffic when combined stats fail', () async {
      final container = buildContainer();
      connectCore(container);
      when(() => core.getTrafficStats(any())).thenThrow(StateError('boom'));

      await container.read(commonActionProvider.notifier).updateTraffic();

      expect(container.read(trafficsProvider).list, isEmpty);
    });

    test(
      'drops concurrent in-flight updates while one is in progress',
      () async {
        final container = buildContainer();
        connectCore(container);
        final completer = Completer<({Traffic now, Traffic total})>();
        when(
          () => core.getTrafficStats(any()),
        ).thenAnswer((_) => completer.future);

        final first = container
            .read(commonActionProvider.notifier)
            .updateTraffic();
        final second = container
            .read(commonActionProvider.notifier)
            .updateTraffic();

        await expectLater(second, completes);
        completer.complete((
          now: const Traffic(up: 5, down: 10),
          total: const Traffic(up: 5, down: 10),
        ));
        await first;

        verify(() => core.getTrafficStats(any())).called(1);
      },
    );
  });

  group('CommonAction.autoCheckUpdate', () {
    test('returns without a network call when the setting is off', () async {
      final container = buildContainer();
      container
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(autoCheckUpdate: false));

      await expectLater(
        container.read(commonActionProvider.notifier).autoCheckUpdate(),
        completion(isFalse),
      );
    });
  });
}
