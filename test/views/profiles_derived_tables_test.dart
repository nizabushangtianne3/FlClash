import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/profiles/custom/custom.dart';
import 'package:fl_clash/views/profiles/custom/custom_proxies.dart';
import 'package:fl_clash/views/profiles/custom/members.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

const _group = ProxyGroup(
  id: 1,
  profileId: 1,
  name: 'Group',
  type: GroupType.Selector,
  proxies: ['DIRECT'],
);

const _proxies = [
  CustomProxy(
    id: 1,
    definition: {'name': 'HK', 'type': 'ss', 'server': 'hk.example.com'},
  ),
  CustomProxy(
    id: 2,
    definition: {'name': 'JP', 'type': 'vless', 'server': 'jp.example.com'},
  ),
];

final _membersData = CustomProfileData(
  proxyGroups: [_group],
  proxies: {'DIRECT'},
  ruleTargets: RuleTarget.baseTargets,
);

final _sectionsData = CustomProfileData(
  proxyGroups: [_group],
  dialers: {'HK': 'JP'},
  proxies: {'DIRECT'},
  ruleTargets: RuleTarget.baseTargets,
);

class _Proxies extends CustomProxies {
  _Proxies();

  @override
  Stream<List<CustomProxy>> build() => Stream.value(_proxies);
}

class _ProxyGroups extends ProxyGroups {
  _ProxyGroups();

  @override
  Stream<List<ProxyGroup>> build(int profileId) => Stream.value([_group]);
}

class _Rules extends ProfileRules {
  _Rules();

  @override
  Stream<List<Rule>> build(int profileId) => Stream.value(const []);
}

class _ClashProviders extends ClashProvidersAction {
  _ClashProviders();

  @override
  Future<void> applyIfProxiesNamed(Set<String> names) async {}
}

void _setViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'members rows hold their type tables while the data is unchanged',
    (tester) async {
      _setViewport(tester);
      final profile = Profile.custom();
      final container = ProviderContainer(
        overrides: [
          proxyGroupProvider.overrideWithValue(
            _group.copyWith(profileId: profile.id),
          ),
          customProfileDataProvider(profile.id).overrideWithValue(_membersData),
          customProxiesProvider.overrideWith(() => _Proxies()),
        ],
      );
      addTearDown(container.dispose);
      globalState.container = container;
      container
          .read(viewSizeProvider.notifier)
          .update((_) => const Size(1400, 1000));

      Widget page() {
        return UncontrolledProviderScope(
          container: container,
          child: TestApp(
            child: ProfileIdProvider(
              profileId: profile.id,
              child: const Scaffold(
                body: CustomScrollView(slivers: [ProxyGroupMembersSliver()]),
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(page());
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);
      expect(memberTableRebuilds, greaterThan(0));

      memberTableRebuilds = 0;
      await tester.pumpWidget(page());
      await tester.pump();
      expect(memberTableRebuilds, 0);
    },
  );

  testWidgets('the proxies list holds its id set while the data is unchanged', (
    tester,
  ) async {
    _setViewport(tester);
    final container = ProviderContainer(
      overrides: [
        customGroupNamesProvider.overrideWith(
          (_) => Stream.value(const <String>{}),
        ),
        customProxiesProvider.overrideWith(() => _Proxies()),
        customProxyCoreErrorsProvider.overrideWith((_) async => const {}),
        clashProvidersActionProvider.overrideWith(() => _ClashProviders()),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    container
        .read(viewSizeProvider.notifier)
        .update((_) => const Size(1400, 1000));

    const view = TestApp(child: CustomProxiesView());
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: view),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(CustomProxiesView), findsOneWidget);
    expect(proxyIdTableRebuilds, greaterThan(0));

    proxyIdTableRebuilds = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: view),
    );
    await tester.pump();
    expect(proxyIdTableRebuilds, 0);
  });

  testWidgets(
    'profile sections hold their counts while the data is unchanged',
    (tester) async {
      _setViewport(tester);
      final profile = Profile.custom();
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([profile])),
          currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
          profileRulesProvider.overrideWith2((_) => _Rules()),
          proxyGroupsProvider.overrideWith2((_) => _ProxyGroups()),
          customProfileDataProvider(
            profile.id,
          ).overrideWithValue(_sectionsData),
        ],
      );
      addTearDown(container.dispose);
      globalState.container = container;
      container
          .read(viewSizeProvider.notifier)
          .update((_) => const Size(1400, 1000));

      final view = TestApp(child: CustomProfileView(profileId: profile.id));
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: view),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(overviewTableRebuilds, greaterThan(0));

      overviewTableRebuilds = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: view),
      );
      await tester.pump();
      expect(overviewTableRebuilds, 0);
    },
  );
}
