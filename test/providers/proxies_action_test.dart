import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/test_profiles.dart';

class MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

class _RecordingCoreController extends CoreController {
  _RecordingCoreController(this.onGetProxiesGroups)
    : super.scoped(MockCoreHandlerInterface());

  final Future<List<Group>> Function(Map<String, String> selectedMap)
  onGetProxiesGroups;

  @override
  Future<List<Group>> getProxiesGroups({
    required ProxiesSortType sortType,
    required DelayMap delayMap,
    required Map<String, String> selectedMap,
    required String defaultTestUrl,
    bool forceFull = false,
  }) {
    return onGetProxiesGroups(selectedMap);
  }
}

class _CountingProxiesAction extends ProxiesAction {
  int resortCalls = 0;

  @override
  Future<void> resortGroupsByDelay() async {
    resortCalls++;
  }
}

const _testUrl = 'http://delay.test';

Group _group(String name, List<Proxy> all) =>
    Group(type: GroupType.Selector, name: name, all: all);

const _proxy = Proxy(name: 'HK-01', type: 'ss');

Profile _selectedProfile(String proxyName) => Profile(
  id: 1,
  autoUpdateDuration: Duration.zero,
  selectedMap: {'Proxy': proxyName},
);

final _delayKey = delayTestKey(_testUrl, 'HK-01');

ProviderContainer _delayContainer(ProviderContainer Function() build) {
  final container = build();
  container.read(appSettingProvider.notifier).value = const AppSettingProps(
    testUrl: _testUrl,
  );
  return container;
}

ExternalProvider _provider(String name, {int count = 1}) => ExternalProvider(
  name: name,
  type: 'Proxy',
  count: count,
  vehicleType: 'HTTP',
  updateAt: DateTime.utc(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockCoreHandlerInterface core;

  setUpAll(() async {
    registerFallbackValue(
      const ChangeProxyParams(groupName: 'G', proxyName: 'P'),
    );
    core = MockCoreHandlerInterface();
    await AppLocalizations.load(const Locale('en'));
  });

  setUp(() => reset(core));

  ProviderContainer buildContainer({
    Profile? profile,
    CoreController? coreController,
    List<Override> extraOverrides = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(
          coreController ?? CoreController.scoped(core),
        ),
        profilesProvider.overrideWith(() => TestProfiles([?profile])),
        currentProfileIdProvider.overrideWithBuild((_, _) => profile?.id),
        ...extraOverrides,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  ProxiesAction actionOf(ProviderContainer container) =>
      container.read(proxiesActionProvider.notifier);

  ProviderContainer runningContainer() {
    final container = buildContainer();
    container.read(initProvider.notifier).value = true;
    container.read(runTimeProvider.notifier).value = 1;
    return container;
  }

  group('updateGroups', () {
    test('does not schedule a delay resort for non-delay sorting', () async {
      addTearDown(() => debouncer.cancel(FunctionTag.updateDelay));
      final container = buildContainer(
        extraOverrides: [
          proxiesActionProvider.overrideWith(_CountingProxiesAction.new),
        ],
      );
      container
          .read(proxiesStyleSettingProvider.notifier)
          .update((state) => state.copyWith(sortType: ProxiesSortType.name));
      final action =
          container.read(proxiesActionProvider.notifier)
              as _CountingProxiesAction;

      action.resortGroupsByDelayDebounce(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(action.resortCalls, 0);
    });

    test('publishes the groups derived from core proxy data', () async {
      when(core.getProxies).thenAnswer(
        (_) async => const ProxiesSnapshot(
          generation: 0,
          full: true,
          data: ProxiesData(
            all: ['Proxy', 'Direct'],
            proxies: {
              'Proxy': {
                'name': 'Proxy',
                'type': 'Selector',
                'now': 'HK-01',
                'all': ['HK-01'],
              },
              'Direct': {'name': 'Direct', 'type': 'Direct'},
              'HK-01': {'name': 'HK-01', 'type': 'ss'},
            },
          ),
          selected: {},
        ),
      );
      final container = buildContainer();

      await actionOf(container).updateGroups();

      final groups = container.read(groupsProvider);
      expect(groups.map((group) => group.name), ['Proxy']);
      expect(groups.single.all.map((proxy) => proxy.name), ['HK-01']);
    });

    test(
      'publishes the groups once a retry succeeds after core throws',
      () async {
        var attempt = 0;
        when(core.getProxies).thenAnswer((_) async {
          attempt++;
          if (attempt == 1) {
            throw StateError('core down');
          }
          return const ProxiesSnapshot(
            generation: 0,
            full: true,
            data: ProxiesData(
              all: ['Proxy', 'Direct'],
              proxies: {
                'Proxy': {
                  'name': 'Proxy',
                  'type': 'Selector',
                  'now': 'HK-01',
                  'all': ['HK-01'],
                },
                'Direct': {'name': 'Direct', 'type': 'Direct'},
                'HK-01': {'name': 'HK-01', 'type': 'ss'},
              },
            ),
            selected: {},
          );
        });
        final container = buildContainer();

        await actionOf(container).updateGroups();

        final groups = container.read(groupsProvider);
        expect(groups.map((group) => group.name), ['Proxy']);
        verify(core.getProxies).called(2);
      },
    );

    test(
      'clears the groups once retry is exhausted after core throws',
      () async {
        when(core.getProxies).thenThrow(StateError('core down'));
        final container = buildContainer();
        container.read(groupsProvider.notifier).value = [
          _group('Stale', const []),
        ];

        await actionOf(container).updateGroups();

        expect(container.read(groupsProvider), isEmpty);
        verify(core.getProxies).called(3);
      },
    );

    test('retries with the latest selection state', () async {
      final seenSelections = <Map<String, String>>[];
      late ProviderContainer container;
      final coreController = _RecordingCoreController((selectedMap) async {
        seenSelections.add(Map.of(selectedMap));
        if (seenSelections.length == 1) {
          final profile = container.read(currentProfileProvider)!;
          container
              .read(profilesProvider.notifier)
              .put(profile.copyWith(selectedMap: {'Proxy': 'HK-01'}));
          return const <Group>[];
        }
        return [
          _group('Proxy', const [_proxy]),
        ];
      });
      container = buildContainer(
        profile: _selectedProfile('HK-00'),
        coreController: coreController,
      );

      await actionOf(container).updateGroups();

      expect(seenSelections, [
        {'Proxy': 'HK-00'},
        {'Proxy': 'HK-01'},
      ]);
      expect(container.read(groupsProvider).single.name, 'Proxy');
    });

    test('does not retry a deterministic Core error', () async {
      var calls = 0;
      final coreController = _RecordingCoreController((_) async {
        calls++;
        throw const CoreMethodException(code: 'unsupported', message: 'no');
      });
      final container = buildContainer(coreController: coreController);
      container.read(groupsProvider.notifier).value = [
        _group('Stale', const []),
      ];

      await actionOf(container).updateGroups();

      expect(calls, 1);
      expect(container.read(groupsProvider).single.name, 'Stale');
    });

    test('still retries a transient Core error', () async {
      var calls = 0;
      final coreController = _RecordingCoreController((_) async {
        calls++;
        throw const CoreMethodException(
          code: 'internal_error',
          message: 'temporary',
        );
      });
      final container = buildContainer(coreController: coreController);

      await actionOf(container).updateGroups();

      expect(calls, 3);
    });

    test('coalesces concurrent updates into one trailing refresh', () async {
      var calls = 0;
      final gates = [
        Completer<ProxiesSnapshot>(),
        Completer<ProxiesSnapshot>(),
      ];
      when(core.getProxies).thenAnswer((_) => gates[calls++].future);
      ProxiesSnapshot snapshot(String proxy, int generation) => ProxiesSnapshot(
        generation: generation,
        full: true,
        data: ProxiesData(
          all: ['Proxy', proxy],
          proxies: {
            'Proxy': {
              'name': 'Proxy',
              'type': 'Selector',
              'now': proxy,
              'all': [proxy],
            },
            proxy: {'name': proxy, 'type': 'ss'},
          },
        ),
        selected: const {},
      );
      final container = buildContainer();
      final action = actionOf(container);

      final first = action.updateGroups();
      await Future<void>.delayed(Duration.zero);
      final second = action.updateGroups();
      final third = action.updateGroups();
      gates[0].complete(snapshot('HK-01', 0));
      await Future<void>.delayed(Duration.zero);
      gates[1].complete(snapshot('HK-02', 1));
      await Future.wait([first, second, third]);

      expect(calls, 2);
      expect(container.read(groupsProvider).single.all.single.name, 'HK-02');
    });

    test('a core status change alone does not clear the groups', () {
      final container = buildContainer();
      actionOf(container);
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      container.read(groupsProvider.notifier).value = [
        _group('Stale', const []),
      ];

      container.read(coreStatusProvider.notifier).value =
          CoreStatus.disconnected;

      expect(container.read(groupsProvider).map((group) => group.name), [
        'Stale',
      ]);
    });
  });

  group('changeProxy', () {
    setUp(() {
      when(
        () => core.changeProxy(any()),
      ).thenAnswer((_) async => const ChangeProxyResult(changed: true));
      when(core.closeConnections).thenAnswer((_) async => true);
      when(core.resetConnections).thenAnswer((_) async => true);
    });

    test('closes connections when enabled', () async {
      final container = runningContainer();
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        closeConnections: true,
      );

      await actionOf(
        container,
      ).changeProxy(groupName: 'Proxy', proxyName: 'HK-01');

      verify(
        () => core.changeProxy(
          const ChangeProxyParams(groupName: 'Proxy', proxyName: 'HK-01'),
        ),
      ).called(1);
      verify(core.closeConnections).called(1);
      verifyNever(core.resetConnections);
    });

    test('resets connections instead when the setting is off', () async {
      final container = buildContainer();
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        closeConnections: false,
      );

      await actionOf(
        container,
      ).changeProxy(groupName: 'Proxy', proxyName: 'HK-01');

      verify(core.resetConnections).called(1);
      verifyNever(core.closeConnections);
    });

    test('a failing connection reset does not fail the switch', () async {
      when(core.closeConnections).thenThrow(
        const CoreMethodException(
          code: 'transport_disconnected',
          message: 'Core RPC client is closed',
        ),
      );
      final container = buildContainer(profile: _selectedProfile('HK-00'));
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        closeConnections: true,
      );

      await actionOf(
        container,
      ).changeProxy(groupName: 'Proxy', proxyName: 'HK-01');

      verify(core.closeConnections).called(1);
      expect(container.read(currentProfileProvider)?.selectedMap, {
        'Proxy': 'HK-01',
      });
    });

    test('serializes connection cleanup across switches', () async {
      final gate = Completer<void>();
      var cleanupCalls = 0;
      when(core.closeConnections).thenAnswer((_) async {
        cleanupCalls++;
        await gate.future;
        return true;
      });
      final container = runningContainer();
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        closeConnections: true,
      );
      final action = actionOf(container);

      await action.changeProxy(groupName: 'Proxy', proxyName: 'HK-01');
      await action.changeProxy(groupName: 'Proxy', proxyName: 'HK-02');
      await Future<void>.delayed(Duration.zero);
      expect(cleanupCalls, 1);

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(cleanupCalls, 2);
    });

    test('coalesces a burst of connection cleanups', () async {
      final gate = Completer<void>();
      var cleanupCalls = 0;
      when(core.closeConnections).thenAnswer((_) async {
        cleanupCalls++;
        if (cleanupCalls == 1) {
          await gate.future;
        }
        return true;
      });
      final container = runningContainer();
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        closeConnections: true,
      );
      final action = actionOf(container);

      for (var index = 0; index < 5; index++) {
        await action.changeProxy(groupName: 'Proxy', proxyName: 'HK-0$index');
      }
      await Future<void>.delayed(Duration.zero);
      expect(cleanupCalls, 1);

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(cleanupCalls, 2);
    });

    test('a direct switch cancels a pending debounced switch', () async {
      addTearDown(() => debouncer.cancel((FunctionTag.changeProxy, 'Proxy')));
      final container = buildContainer(profile: _selectedProfile('HK-00'));
      final action = actionOf(container);

      action.changeProxyDebounce('Proxy', 'HK-01');
      await action.changeProxy(groupName: 'Proxy', proxyName: 'HK-02');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      verify(
        () => core.changeProxy(
          const ChangeProxyParams(groupName: 'Proxy', proxyName: 'HK-02'),
        ),
      ).called(1);
      verifyNever(
        () => core.changeProxy(
          const ChangeProxyParams(groupName: 'Proxy', proxyName: 'HK-01'),
        ),
      );
    });

    test('skips the connection reset when the switch itself fails', () async {
      when(() => core.changeProxy(any())).thenThrow(StateError('core down'));
      final container = runningContainer();

      await actionOf(
        container,
      ).changeProxy(groupName: 'Proxy', proxyName: 'HK-01');

      verifyNever(core.closeConnections);
      verifyNever(core.resetConnections);
    });

    test(
      'skips the connection reset when the Core reports no change',
      () async {
        when(
          () => core.changeProxy(any()),
        ).thenAnswer((_) async => const ChangeProxyResult(changed: false));
        final container = runningContainer();

        await actionOf(
          container,
        ).changeProxy(groupName: 'Proxy', proxyName: 'HK-01');

        verifyNever(core.closeConnections);
        verifyNever(core.resetConnections);
      },
    );

    test('rolls the selection back when the Core answers a message', () async {
      when(() => core.changeProxy(any())).thenAnswer(
        (_) async => const ChangeProxyResult(message: 'proxy not exist'),
      );
      final container = buildContainer(profile: _selectedProfile('HK-00'));

      await actionOf(
        container,
      ).changeProxy(groupName: 'Proxy', proxyName: 'HK-01');

      verifyNever(core.closeConnections);
      expect(container.read(currentProfileProvider)?.selectedMap, {
        'Proxy': 'HK-00',
      });
    });

    test('commits the selection the Core accepted', () async {
      final container = buildContainer(profile: _selectedProfile('HK-00'));

      await actionOf(
        container,
      ).changeProxy(groupName: 'Proxy', proxyName: 'HK-01');

      expect(container.read(currentProfileProvider)?.selectedMap, {
        'Proxy': 'HK-01',
      });
    });

    test('rolls the selection back when the switch fails', () async {
      when(() => core.changeProxy(any())).thenThrow(StateError('core down'));
      final container = buildContainer(profile: _selectedProfile('HK-00'));

      await actionOf(
        container,
      ).changeProxy(groupName: 'Proxy', proxyName: 'HK-01');

      expect(container.read(currentProfileProvider)?.selectedMap, {
        'Proxy': 'HK-00',
      });
    });

    test(
      'rolls back to the last selection the Core applied, not the last tap',
      () async {
        when(() => core.changeProxy(any())).thenThrow(StateError('core down'));
        final container = buildContainer(profile: _selectedProfile('HK-00'));
        final action = actionOf(container);

        action.changeProxyDebounce('Proxy', 'HK-01');
        action.changeProxyDebounce('Proxy', 'HK-02');
        expect(container.read(currentProfileProvider)?.selectedMap, {
          'Proxy': 'HK-02',
        });

        await action.changeProxy(groupName: 'Proxy', proxyName: 'HK-02');

        expect(container.read(currentProfileProvider)?.selectedMap, {
          'Proxy': 'HK-00',
        });
        debouncer.cancel((FunctionTag.changeProxy, 'Proxy'));
      },
    );

    test('a stale completion cannot overwrite the newest switch', () async {
      final first = Completer<ChangeProxyResult>();
      final second = Completer<ChangeProxyResult>();
      when(() => core.changeProxy(any())).thenAnswer((invocation) {
        final params =
            invocation.positionalArguments.single as ChangeProxyParams;
        return params.proxyName == 'HK-01' ? first.future : second.future;
      });
      final container = buildContainer(profile: _selectedProfile('HK-00'));
      container.read(groupsProvider.notifier).value = [
        _group('Proxy', const [
          Proxy(name: 'HK-01', type: 'ss'),
          Proxy(name: 'HK-02', type: 'ss'),
        ]),
      ];
      final action = actionOf(container);

      final firstRun = action.changeProxy(
        groupName: 'Proxy',
        proxyName: 'HK-01',
      );
      final secondRun = action.changeProxy(
        groupName: 'Proxy',
        proxyName: 'HK-02',
      );

      first.complete(const ChangeProxyResult(changed: true));
      await firstRun;
      expect(container.read(currentProfileProvider)?.selectedMap, {
        'Proxy': 'HK-02',
      });

      second.completeError(StateError('second switch failed'));
      await secondRun;
      expect(container.read(currentProfileProvider)?.selectedMap, {
        'Proxy': 'HK-01',
      });
    });

    test(
      'a stale success cannot overwrite an already applied switch',
      () async {
        final first = Completer<ChangeProxyResult>();
        final second = Completer<ChangeProxyResult>();
        when(() => core.changeProxy(any())).thenAnswer((invocation) {
          final params =
              invocation.positionalArguments.single as ChangeProxyParams;
          return params.proxyName == 'HK-01' ? first.future : second.future;
        });
        final container = buildContainer(profile: _selectedProfile('HK-00'));
        container.read(groupsProvider.notifier).value = [
          _group('Proxy', const [
            Proxy(name: 'HK-01', type: 'ss'),
            Proxy(name: 'HK-02', type: 'ss'),
          ]),
        ];
        final action = actionOf(container);

        final firstRun = action.changeProxy(
          groupName: 'Proxy',
          proxyName: 'HK-01',
        );
        final secondRun = action.changeProxy(
          groupName: 'Proxy',
          proxyName: 'HK-02',
        );

        second.complete(const ChangeProxyResult(changed: true));
        await secondRun;
        expect(container.read(groupsProvider).single.now, 'HK-02');

        first.complete(const ChangeProxyResult(changed: true));
        await firstRun;

        expect(container.read(currentProfileProvider)?.selectedMap, {
          'Proxy': 'HK-02',
        });
        expect(container.read(groupsProvider).single.now, 'HK-02');
      },
    );

    test('a stale success does not clean up connections again', () async {
      final first = Completer<ChangeProxyResult>();
      final second = Completer<ChangeProxyResult>();
      when(() => core.changeProxy(any())).thenAnswer((invocation) {
        final params =
            invocation.positionalArguments.single as ChangeProxyParams;
        return params.proxyName == 'HK-01' ? first.future : second.future;
      });
      var cleanupCalls = 0;
      when(core.closeConnections).thenAnswer((_) async {
        cleanupCalls++;
        return true;
      });
      final container = buildContainer(profile: _selectedProfile('HK-00'));
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        closeConnections: true,
      );
      final action = actionOf(container);

      final firstRun = action.changeProxy(
        groupName: 'Proxy',
        proxyName: 'HK-01',
      );
      final secondRun = action.changeProxy(
        groupName: 'Proxy',
        proxyName: 'HK-02',
      );

      second.complete(const ChangeProxyResult(changed: true));
      await secondRun;
      await Future<void>.delayed(Duration.zero);
      expect(cleanupCalls, 1);

      first.complete(const ChangeProxyResult(changed: true));
      await firstRun;
      await Future<void>.delayed(Duration.zero);
      expect(cleanupCalls, 1);
    });
  });

  group('delay sorting', () {
    test('puts untested nodes last while a batch runs', () async {
      final gates = {
        'HK-01': Completer<Delay?>(),
        'HK-02': Completer<Delay?>(),
      };
      when(() => core.asyncTestDelay(_testUrl, any())).thenAnswer(
        (invocation) =>
            gates[invocation.positionalArguments[1] as String]?.future ??
            Future<Delay?>.value(),
      );
      const proxies = [
        Proxy(name: 'HK-02', type: 'ss'),
        Proxy(name: 'HK-01', type: 'ss'),
        Proxy(name: 'HK-03', type: 'ss'),
      ];
      final container = _delayContainer(buildContainer);
      container.listen(proxiesStyleSettingProvider, (_, _) {});
      container
          .read(proxiesStyleSettingProvider.notifier)
          .update((state) => state.copyWith(sortType: ProxiesSortType.delay));
      expect(
        container.read(proxiesStyleSettingProvider).sortType,
        ProxiesSortType.delay,
      );
      final action = actionOf(container);
      container.read(groupsProvider.notifier).value = [
        const Group(
          type: GroupType.Selector,
          name: 'Proxy',
          testUrl: _testUrl,
          all: proxies,
        ),
      ];

      final run = action.delayTest(proxies);
      await Future<void>.delayed(Duration.zero);
      gates['HK-01']!.complete(
        const Delay(name: 'HK-01', url: _testUrl, value: 50),
      );
      await Future<void>.delayed(renderThrottleDuration * 2);
      await action.resortGroupsByDelay();

      expect(
        container.read(groupsProvider).single.all.map((proxy) => proxy.name),
        ['HK-01', 'HK-02', 'HK-03'],
      );

      gates['HK-02']!.complete(
        const Delay(name: 'HK-02', url: _testUrl, value: 200),
      );
      await run;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(delayDataSourceProvider)[_testUrl], {
        'HK-01': 50,
        'HK-02': 200,
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        container.read(groupsProvider).single.all.map((proxy) => proxy.name),
        ['HK-01', 'HK-02', 'HK-03'],
      );
    });

    test('keeps a groups update that lands while a sort runs', () async {
      final container = _delayContainer(buildContainer);
      container.listen(proxiesStyleSettingProvider, (_, _) {});
      container
          .read(proxiesStyleSettingProvider.notifier)
          .update((state) => state.copyWith(sortType: ProxiesSortType.delay));
      final action = actionOf(container);

      final stale = [
        _group('Proxy', const [
          Proxy(name: 'HK-02', type: 'ss'),
          Proxy(name: 'HK-01', type: 'ss'),
        ]),
      ];
      container.read(groupsProvider.notifier).value = stale;
      container.read(delayDataSourceProvider.notifier).value = {
        _testUrl: {'HK-01': 50, 'HK-02': 200},
      };

      final resort = action.resortGroupsByDelay();
      final newer = [
        _group('Newer', const [_proxy]),
      ];
      container.read(groupsProvider.notifier).value = newer;
      await resort;

      expect(container.read(groupsProvider), same(newer));
    });
  });

  group('route picks', () {
    test('updates group selection from the Core pick map', () {
      final container = buildContainer();
      container.read(groupsProvider.notifier).value = [
        _group('Proxy', const [_proxy]),
      ];

      actionOf(container).applyRoutePicks(const {'Proxy': 'HK-01'});

      expect(container.read(groupsProvider).single.now, 'HK-01');
    });

    test('closes connections after an automatic pick change', () async {
      when(core.closeConnections).thenAnswer((_) async => true);
      final container = buildContainer();
      container.read(groupsProvider.notifier).value = [
        _group('Proxy', const [_proxy]),
      ];

      actionOf(
        container,
      ).applyRoutePicks(const {'Proxy': 'HK-01'}, closeConnections: true);
      await Future<void>.delayed(const Duration(milliseconds: 1));

      verify(core.closeConnections).called(1);
    });

    test('does not overwrite a selection that is still applying', () async {
      final release = Completer<ChangeProxyResult>();
      when(() => core.changeProxy(any())).thenAnswer((_) => release.future);
      final container = buildContainer(profile: _selectedProfile('HK-01'));
      container.read(groupsProvider.notifier).value = [
        _group('Proxy', const [_proxy, Proxy(name: 'HK-02', type: 'ss')]),
      ];
      final action = actionOf(container);

      final run = action.changeProxy(groupName: 'Proxy', proxyName: 'HK-02');
      action.applyRoutePicks(const {'Proxy': 'HK-01'});

      expect(container.read(groupsProvider).single.now, isNull);

      release.complete(const ChangeProxyResult(changed: false));
      await run;
    });
  });

  group('proxyDelayTest', () {
    test('marks the node pending while it runs, then records it', () async {
      late ProviderContainer container;
      final observed = <bool>[];
      when(() => core.asyncTestDelay(_testUrl, 'HK-01')).thenAnswer((_) async {
        observed.add(
          container.read(pendingDelayTestsProvider).containsKey(_delayKey),
        );
        return const Delay(name: 'HK-01', url: _testUrl, value: 128);
      });
      container = _delayContainer(buildContainer);

      await actionOf(container).proxyDelayTest(_proxy);

      expect(observed, [true]);
      expect(container.read(delayDataSourceProvider)[_testUrl]?['HK-01'], 128);
      expect(container.read(pendingDelayTestsProvider), isEmpty);
    });

    test('keeps the last measurement when the Core does not answer', () async {
      when(
        () => core.asyncTestDelay(_testUrl, 'HK-01'),
      ).thenAnswer((_) async => null);
      final container = _delayContainer(buildContainer);
      container
          .read(delayDataSourceProvider.notifier)
          .setDelay(const Delay(name: 'HK-01', url: _testUrl, value: 42));

      await actionOf(container).proxyDelayTest(_proxy);

      expect(container.read(delayDataSourceProvider)[_testUrl]?['HK-01'], 42);
      expect(container.read(pendingDelayTestsProvider), isEmpty);
    });

    test('falls back to untested when a throwing call had no value', () async {
      when(
        () => core.asyncTestDelay(_testUrl, 'HK-01'),
      ).thenThrow(StateError('channel is gone'));
      final container = _delayContainer(buildContainer);

      await actionOf(container).proxyDelayTest(_proxy);

      expect(container.read(delayDataSourceProvider)[_testUrl]?['HK-01'], null);
      expect(container.read(pendingDelayTestsProvider), isEmpty);
    });

    test('does nothing when the resolved proxy name is empty', () async {
      final container = buildContainer();

      await actionOf(container).proxyDelayTest(const Proxy(name: '', type: ''));

      expect(container.read(delayDataSourceProvider), isEmpty);
      expect(container.read(pendingDelayTestsProvider), isEmpty);
      verifyNever(() => core.asyncTestDelay(any(), any()));
    });
  });

  group('delayTest', () {
    test('coalesces repeated buffered values for the same target', () async {
      final container = _delayContainer(buildContainer);
      final action = actionOf(container);

      action.setDelay(const Delay(name: 'HK-01', url: _testUrl, value: 120));
      action.setDelay(const Delay(name: 'HK-01', url: _testUrl, value: 80));
      await Future<void>.delayed(renderThrottleDuration * 2);

      expect(container.read(delayDataSourceProvider)[_testUrl], {'HK-01': 80});
    });

    test('shares an in-flight delay probe across overlapping runs', () async {
      var calls = 0;
      final answer = Completer<Delay?>();
      when(() => core.asyncTestDelay(_testUrl, 'HK-01')).thenAnswer((_) {
        calls++;
        return answer.future;
      });
      final container = _delayContainer(buildContainer);
      final action = actionOf(container);

      final first = action.proxyDelayTest(_proxy);
      final second = action.proxyDelayTest(_proxy);
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);
      answer.complete(const Delay(name: 'HK-01', url: _testUrl, value: 24));
      await Future.wait([first, second]);
      await Future<void>.delayed(renderThrottleDuration * 2);

      expect(container.read(delayDataSourceProvider)[_testUrl], {'HK-01': 24});
    });

    test('interactive probes start before queued bulk probes', () async {
      final firstBatch = {
        for (var index = 0; index < maxConcurrentDelayTests; index++)
          'HK-$index': Completer<Delay?>(),
      };
      final urgent = Completer<Delay?>();
      final started = <String>[];
      when(() => core.asyncTestDelay(any(), 'URGENT')).thenAnswer((_) {
        started.add('URGENT');
        return urgent.future;
      });
      when(() => core.asyncTestDelay(_testUrl, any())).thenAnswer((invocation) {
        final name = invocation.positionalArguments[1] as String;
        started.add(name);
        final gate = firstBatch[name];
        if (gate != null) {
          return gate.future;
        }
        return Future.value(Delay(name: name, url: _testUrl, value: 8));
      });
      final container = _delayContainer(buildContainer);
      final action = actionOf(container);
      final bulk = action.delayTest([
        for (var index = 0; index < maxConcurrentDelayTests + 8; index++)
          Proxy(name: 'HK-$index', type: 'ss'),
      ]);
      await Future<void>.delayed(Duration.zero);

      final interactive = action.proxyDelayTest(
        const Proxy(name: 'URGENT', type: 'ss'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(started, isNot(contains('URGENT')));
      expect(started, isNot(contains('HK-32')));

      firstBatch['HK-0']!.complete(null);
      await Future<void>.delayed(renderThrottleDuration * 2);
      expect(started, contains('URGENT'));
      expect(started, isNot(contains('HK-32')));

      urgent.complete(const Delay(name: 'URGENT', url: _testUrl, value: 6));
      for (final gate in firstBatch.values) {
        if (!gate.isCompleted) {
          gate.complete(null);
        }
      }
      await Future.wait([bulk, interactive]);
    });

    test('measures every proxy and bumps the sort counter', () async {
      when(() => core.asyncTestDelay(_testUrl, any())).thenAnswer(
        (invocation) async => Delay(
          name: invocation.positionalArguments[1] as String,
          url: _testUrl,
          value: 10,
        ),
      );
      final container = _delayContainer(buildContainer);
      final before = container.read(sortNumProvider);

      await actionOf(
        container,
      ).delayTest(const [_proxy, Proxy(name: 'HK-02', type: 'ss')]);

      final delays = container.read(delayDataSourceProvider)[_testUrl];
      expect(delays?['HK-01'], 10);
      expect(delays?['HK-02'], 10);
      expect(container.read(sortNumProvider), before + 1);
      expect(container.read(pendingDelayTestsProvider), isEmpty);
    });

    test('lands a run of quick results in batches, not one per node', () async {
      when(() => core.asyncTestDelay(_testUrl, any())).thenAnswer(
        (invocation) async => Delay(
          name: invocation.positionalArguments[1] as String,
          url: _testUrl,
          value: 10,
        ),
      );
      final container = _delayContainer(buildContainer);
      var delayChanges = 0;
      var pendingChanges = 0;
      container.listen(delayDataSourceProvider, (_, _) => delayChanges++);
      container.listen(pendingDelayTestsProvider, (_, _) => pendingChanges++);
      final proxies = List.generate(
        1000,
        (index) => Proxy(name: 'HK-$index', type: 'ss'),
      );

      await actionOf(container).delayTest(proxies);

      expect(
        container.read(delayDataSourceProvider)[_testUrl],
        hasLength(1000),
      );
      expect(container.read(pendingDelayTestsProvider), isEmpty);
      expect(delayChanges, 1);
      expect(pendingChanges, lessThanOrEqualTo(2));
    });

    test(
      'marks only nodes the pool runs as running, the rest queued',
      () async {
        final answers = <String, Completer<Delay?>>{};
        when(() => core.asyncTestDelay(_testUrl, any())).thenAnswer(
          (invocation) => answers
              .putIfAbsent(
                invocation.positionalArguments[1] as String,
                Completer<Delay?>.new,
              )
              .future,
        );
        final container = _delayContainer(buildContainer);
        final proxies = List.generate(
          maxConcurrentDelayTests + 1,
          (index) => Proxy(name: 'HK-$index', type: 'ss'),
        );
        DelayTestPhase? phaseOf(int index) => container.read(
          pendingDelayTestsProvider,
        )[delayTestKey(_testUrl, 'HK-$index')];

        final run = actionOf(container).delayTest(proxies);

        expect(phaseOf(0), DelayTestPhase.running);
        expect(phaseOf(maxConcurrentDelayTests - 1), DelayTestPhase.running);
        expect(phaseOf(maxConcurrentDelayTests), DelayTestPhase.queued);

        answers['HK-0']!.complete(null);
        await Future<void>.delayed(renderThrottleDuration * 2);

        expect(phaseOf(0), isNull);
        expect(phaseOf(maxConcurrentDelayTests), DelayTestPhase.running);

        for (final answer in answers.values) {
          if (!answer.isCompleted) {
            answer.complete(null);
          }
        }
        await run;

        expect(container.read(pendingDelayTestsProvider), isEmpty);
      },
    );

    test('a second group starts before the first group drains', () async {
      final gates = <String, Completer<Delay?>>{};
      final started = <String>[];
      when(() => core.asyncTestDelay(any(), any())).thenAnswer((invocation) {
        final name = invocation.positionalArguments[1] as String;
        started.add(name);
        if (name.startsWith('A-')) {
          return gates.putIfAbsent(name, Completer<Delay?>.new).future;
        }
        return Future.value(Delay(name: name, url: _testUrl, value: 10));
      });
      final container = _delayContainer(buildContainer);
      const groupCount = maxConcurrentDelayTests + 8;
      container.read(groupsProvider.notifier).value = [
        _group('A', [
          for (var index = 0; index < groupCount; index++)
            Proxy(name: 'A-$index', type: 'ss'),
        ]),
        _group('B', [
          for (var index = 0; index < groupCount; index++)
            Proxy(name: 'B-$index', type: 'ss'),
        ]),
      ];
      final action = actionOf(container);

      final firstRun = action.delayTestPageGroup('A');
      await Future<void>.delayed(Duration.zero);
      final secondRun = action.delayTestPageGroup('B');
      await Future<void>.delayed(Duration.zero);

      expect(started, contains('A-0'));
      expect(started.where((name) => name.startsWith('B-')), isEmpty);

      gates['A-0']!.complete(null);
      gates['A-1']!.complete(null);
      await Future<void>.delayed(renderThrottleDuration * 2);

      for (var attempt = 0; attempt < 100; attempt++) {
        for (final gate in gates.values) {
          if (!gate.isCompleted) {
            gate.complete(null);
          }
        }
        if (started.length >= groupCount * 2) {
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait([firstRun, secondRun]);

      expect(started, contains('B-0'));
    });

    test('probes a node that appears twice only once', () async {
      when(() => core.asyncTestDelay(_testUrl, 'HK-01')).thenAnswer(
        (_) async => const Delay(name: 'HK-01', url: _testUrl, value: 10),
      );
      final container = _delayContainer(buildContainer);

      await actionOf(container).delayTest(const [_proxy, _proxy]);

      verify(() => core.asyncTestDelay(_testUrl, 'HK-01')).called(1);
    });

    test('skips built-in adapters that cannot be probed', () async {
      when(() => core.asyncTestDelay(_testUrl, any())).thenAnswer(
        (invocation) async => Delay(
          name: invocation.positionalArguments[1] as String,
          url: _testUrl,
          value: 10,
        ),
      );
      final container = _delayContainer(buildContainer);

      await actionOf(container).delayTest(const [
        Proxy(name: 'REJECT', type: 'Reject'),
        Proxy(name: 'DIRECT', type: 'Direct'),
      ]);

      verify(() => core.asyncTestDelay(_testUrl, 'DIRECT')).called(1);
      verifyNever(() => core.asyncTestDelay(_testUrl, 'REJECT'));
    });

    test('testing groups probes a shared node once per test URL', () async {
      const otherUrl = 'http://other.test';
      when(() => core.asyncTestDelay(any(), any())).thenAnswer(
        (invocation) async => Delay(
          url: invocation.positionalArguments[0] as String,
          name: invocation.positionalArguments[1] as String,
          value: 10,
        ),
      );
      final container = _delayContainer(buildContainer);
      final before = container.read(sortNumProvider);

      await actionOf(container).delayTestGroups([
        _group('A', const [_proxy]),
        _group('B', const [_proxy, Proxy(name: 'HK-02', type: 'ss')]),
        const Group(
          type: GroupType.URLTest,
          name: 'C',
          testUrl: otherUrl,
          all: [_proxy],
        ),
      ]);

      verify(() => core.asyncTestDelay(_testUrl, 'HK-01')).called(1);
      verify(() => core.asyncTestDelay(_testUrl, 'HK-02')).called(1);
      verify(() => core.asyncTestDelay(otherUrl, 'HK-01')).called(1);
      expect(container.read(sortNumProvider), before + 1);
    });

    test(
      'testing a page group probes the nodes the timeout filter hides',
      () async {
        when(() => core.asyncTestDelay(_testUrl, any())).thenAnswer(
          (invocation) async => Delay(
            name: invocation.positionalArguments[1] as String,
            url: _testUrl,
            value: 10,
          ),
        );
        final container = _delayContainer(buildContainer);
        container
            .read(groupsProvider.notifier)
            .update(
              (_) => [
                _group('Proxy', const [
                  _proxy,
                  Proxy(name: 'HK-02', type: 'ss'),
                  Proxy(name: 'JP-01', type: 'ss'),
                ]),
              ],
            );
        container
            .read(delayDataSourceProvider.notifier)
            .setDelay(const Delay(url: _testUrl, name: 'HK-02', value: -1));
        container
            .read(proxiesStyleSettingProvider.notifier)
            .update((state) => state.copyWith(hideTimeoutProxies: true));
        container.read(queryProvider(QueryTag.proxies).notifier).value = 'HK';

        await actionOf(container).delayTestPageGroup('Proxy');

        verify(() => core.asyncTestDelay(_testUrl, 'HK-01')).called(1);
        verify(() => core.asyncTestDelay(_testUrl, 'HK-02')).called(1);
        verifyNever(() => core.asyncTestDelay(_testUrl, 'JP-01'));
      },
    );

    test('a page group holds its testing mark until the run settles', () async {
      final release = Completer<Delay?>();
      when(
        () => core.asyncTestDelay(_testUrl, 'HK-01'),
      ).thenAnswer((_) => release.future);
      final container = _delayContainer(buildContainer);
      container
          .read(groupsProvider.notifier)
          .update(
            (_) => [
              _group('Proxy', const [_proxy]),
            ],
          );

      final run = actionOf(container).delayTestPageGroup('Proxy');
      await actionOf(container).delayTestPageGroup('Proxy');

      expect(container.read(delayTestingGroupsProvider), {'Proxy'});
      release.completeError(
        const CoreMethodException(code: 'internal_error', message: 'boom'),
      );
      await run;

      verify(() => core.asyncTestDelay(_testUrl, 'HK-01')).called(1);
      expect(container.read(delayTestingGroupsProvider), isEmpty);
    });

    test('a sweep marks every group it covers until the run settles', () async {
      final release = Completer<Delay?>();
      when(
        () => core.asyncTestDelay(_testUrl, 'HK-01'),
      ).thenAnswer((_) => release.future);
      final container = _delayContainer(buildContainer);

      final run = actionOf(container).delayTestGroups([
        _group('A', const [_proxy]),
        _group('B', const [_proxy]),
      ]);

      expect(container.read(delayTestingGroupsProvider), {'A', 'B'});
      release.completeError(
        const CoreMethodException(code: 'internal_error', message: 'boom'),
      );
      await run;

      expect(container.read(delayTestingGroupsProvider), isEmpty);
    });

    test('stops the run once the transport is gone', () async {
      var calls = 0;
      when(() => core.asyncTestDelay(_testUrl, any())).thenAnswer((_) async {
        calls++;
        throw const CoreMethodException(
          code: 'transport_disconnected',
          message: 'the Core is gone',
        );
      });
      final container = _delayContainer(buildContainer);
      final proxies = List.generate(
        maxConcurrentDelayTests * 3,
        (index) => Proxy(name: 'HK-$index', type: 'ss'),
      );

      await actionOf(container).delayTest(proxies);

      expect(calls, lessThanOrEqualTo(maxConcurrentDelayTests));
      expect(calls, lessThan(proxies.length));
      expect(container.read(delayDataSourceProvider), isEmpty);
      expect(container.read(pendingDelayTestsProvider), isEmpty);
    });

    test('a proxy that answers nothing leaves the rest of the run', () async {
      var calls = 0;
      when(() => core.asyncTestDelay(_testUrl, any())).thenAnswer((
        invocation,
      ) async {
        calls++;
        final name = invocation.positionalArguments[1] as String;
        if (name == 'HK-1') {
          return null;
        }
        return Delay(name: name, url: _testUrl, value: 10);
      });
      final container = _delayContainer(buildContainer);
      final proxies = List.generate(
        8,
        (index) => Proxy(name: 'HK-$index', type: 'ss'),
      );

      await actionOf(container).delayTest(proxies);

      expect(calls, proxies.length);
      final delays = container.read(delayDataSourceProvider)[_testUrl];
      expect(delays?.length, proxies.length - 1);
      expect(delays?['HK-1'], isNull);
      expect(container.read(pendingDelayTestsProvider), isEmpty);
    });

    test('a proxy that fails leaves the rest of the run', () async {
      var calls = 0;
      when(() => core.asyncTestDelay(_testUrl, any())).thenAnswer((
        invocation,
      ) async {
        calls++;
        final name = invocation.positionalArguments[1] as String;
        if (name == 'HK-1') {
          throw const CoreMethodException(
            code: 'internal_error',
            message: 'internal panic',
          );
        }
        return Delay(name: name, url: _testUrl, value: 10);
      });
      final container = _delayContainer(buildContainer);
      final proxies = List.generate(
        8,
        (index) => Proxy(name: 'HK-$index', type: 'ss'),
      );

      await actionOf(container).delayTest(proxies);

      expect(calls, proxies.length);
      final delays = container.read(delayDataSourceProvider)[_testUrl];
      expect(delays?.length, proxies.length - 1);
      expect(delays?['HK-1'], isNull);
      expect(container.read(pendingDelayTestsProvider), isEmpty);
    });

    test('drops every spinner when the Core goes away mid-run', () async {
      final release = Completer<Delay?>();
      when(
        () => core.asyncTestDelay(_testUrl, any()),
      ).thenAnswer((_) => release.future);
      final container = _delayContainer(buildContainer);
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;

      final run = actionOf(
        container,
      ).delayTest(const [_proxy, Proxy(name: 'HK-02', type: 'ss')]);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(pendingDelayTestsProvider), isNotEmpty);

      container.read(coreStatusProvider.notifier).value =
          CoreStatus.disconnected;
      expect(container.read(pendingDelayTestsProvider), isEmpty);

      release.complete(const Delay(name: 'HK-01', url: _testUrl, value: 10));
      await run;

      expect(container.read(delayDataSourceProvider), isEmpty);
      expect(container.read(pendingDelayTestsProvider), isEmpty);
    });
  });

  group('updateProvider', () {
    test(
      'stores the refreshed provider and clears the updating flag',
      () async {
        final refreshed = _provider('geo', count: 5);
        final release = Completer<String>();
        when(
          () => core.updateExternalProvider('geo'),
        ).thenAnswer((_) => release.future);
        when(
          () => core.getExternalProvider('geo'),
        ).thenAnswer((_) async => refreshed);
        final container = buildContainer();
        container.read(providersProvider.notifier).value = [_provider('geo')];

        final update = actionOf(
          container,
        ).updateProvider(_provider('geo'), showLoading: true);

        expect(container.read(isUpdatingProvider('provider_geo')), isTrue);

        release.complete('');
        final message = await update;

        expect(message, isEmpty);
        expect(container.read(providersProvider), [refreshed]);
        expect(container.read(isUpdatingProvider('provider_geo')), isFalse);
      },
    );

    testWidgets('the stale sweep does not interrupt the provider update', (
      tester,
    ) async {
      final refreshed = _provider('geo', count: 8);
      final release = Completer<String>();
      when(
        () => core.updateExternalProvider('geo'),
      ).thenAnswer((_) => release.future);
      when(
        () => core.getExternalProvider('geo'),
      ).thenAnswer((_) async => refreshed);
      final container = buildContainer();
      container.read(updatingActionProvider.notifier);
      container.read(providersProvider.notifier).value = [_provider('geo')];

      final update = actionOf(
        container,
      ).updateProvider(_provider('geo'), showLoading: true);

      await tester.pump(updatingStaleTimeout + updatingSweepInterval);

      expect(container.read(isUpdatingProvider('provider_geo')), isFalse);

      release.complete('');

      expect(await update, isEmpty);
      expect(container.read(providersProvider), [refreshed]);

      await tester.pump(Duration.zero);
    });

    testWidgets('a core disconnect clears the provider updating state', (
      tester,
    ) async {
      final release = Completer<String>();
      when(
        () => core.updateExternalProvider('geo'),
      ).thenAnswer((_) => release.future);
      when(
        () => core.getExternalProvider('geo'),
      ).thenAnswer((_) async => _provider('geo'));
      final container = buildContainer();
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;

      final update = actionOf(
        container,
      ).updateProvider(_provider('geo'), showLoading: true);

      expect(container.read(isUpdatingProvider('provider_geo')), isTrue);

      container.read(coreStatusProvider.notifier).value =
          CoreStatus.disconnected;
      await tester.pump();

      expect(container.read(isUpdatingProvider('provider_geo')), isFalse);

      release.complete('');
      await update;
      await tester.pump(Duration.zero);
    });

    test('returns the core message without storing a provider', () async {
      when(
        () => core.updateExternalProvider('geo'),
      ).thenAnswer((_) async => 'update failed');
      final container = buildContainer();

      final message = await actionOf(
        container,
      ).updateProvider(_provider('geo'), showLoading: true);

      expect(message, 'update failed');
      expect(container.read(providersProvider), isEmpty);
      expect(container.read(isUpdatingProvider('provider_geo')), isFalse);
      verifyNever(() => core.getExternalProvider(any()));
    });

    test('clears the updating flag when core throws', () async {
      when(
        () => core.updateExternalProvider('geo'),
      ).thenThrow(StateError('boom'));
      final container = buildContainer();

      await expectLater(
        actionOf(container).updateProvider(_provider('geo'), showLoading: true),
        throwsStateError,
      );

      expect(container.read(isUpdatingProvider('provider_geo')), isFalse);
    });
  });

  group('sideLoadExternalProvider', () {
    test('stores the provider after a successful side load', () async {
      final refreshed = _provider('rules', count: 3);
      final release = Completer<String>();
      when(
        () => core.sideLoadExternalProvider(
          providerName: 'rules',
          data: 'payload',
        ),
      ).thenAnswer((_) => release.future);
      when(
        () => core.getExternalProvider('rules'),
      ).thenAnswer((_) async => refreshed);
      final container = buildContainer();
      container.read(providersProvider.notifier).value = [_provider('rules')];

      final sideLoad = actionOf(container).sideLoadExternalProvider(
        _provider('rules'),
        'payload',
        showLoading: true,
      );

      expect(container.read(isUpdatingProvider('provider_rules')), isTrue);

      release.complete('');
      final message = await sideLoad;

      expect(message, isEmpty);
      expect(container.read(providersProvider), [refreshed]);
      expect(container.read(isUpdatingProvider('provider_rules')), isFalse);
    });

    test('surfaces the core message and skips the refresh', () async {
      when(
        () => core.sideLoadExternalProvider(providerName: 'rules', data: 'bad'),
      ).thenAnswer((_) async => 'invalid payload');
      final container = buildContainer();

      final message = await actionOf(
        container,
      ).sideLoadExternalProvider(_provider('rules'), 'bad');

      expect(message, 'invalid payload');
      verifyNever(() => core.getExternalProvider(any()));
    });
  });

  group('current profile mutations', () {
    test('updateCurrentGroupName writes the new group onto the profile', () {
      final profile = Profile.normal(label: 'p');
      final container = buildContainer(profile: profile);

      actionOf(container).updateCurrentGroupName('Proxy');

      expect(container.read(profilesProvider).single.currentGroupName, 'Proxy');
    });

    test('updateCurrentGroupName is a no-op for the same group', () {
      final profile = Profile.normal(
        label: 'p',
      ).copyWith(currentGroupName: 'Proxy');
      final container = buildContainer(profile: profile);

      actionOf(container).updateCurrentGroupName('Proxy');

      expect(container.read(profilesProvider).single, same(profile));
    });

    test('updateCurrentUnfoldSet is a no-op without a current profile', () {
      final container = buildContainer();

      expect(
        () => actionOf(container).updateCurrentUnfoldSet({'Proxy'}),
        returnsNormally,
      );
      expect(container.read(profilesProvider), isEmpty);
    });

    test('updateCurrentUnfoldSet stores the set on the current profile', () {
      final profile = Profile.normal(label: 'p');
      final container = buildContainer(profile: profile);

      actionOf(container).updateCurrentUnfoldSet({'Proxy', 'Auto'});

      expect(container.read(profilesProvider).single.unfoldSet, {
        'Proxy',
        'Auto',
      });
    });
  });
}
