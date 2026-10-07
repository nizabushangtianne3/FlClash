part of '../state.dart';

@riverpod
GroupsState currentGroupsState(Ref ref) {
  final mode = ref.watch(
    patchClashConfigProvider.select((state) => state.mode),
  );
  final groups = ref.watch(groupsProvider);
  final shown = switch (mode) {
    Mode.direct => const <Group>[],
    Mode.global => groups,
    Mode.rule => groups.where((item) => item.hidden == false),
  };
  return GroupsState(value: shown.map(_withoutSelection).toList());
}

Group _withoutSelection(Group group) {
  if ((group.now ?? '').isEmpty && !group.all.any(_hasSelection)) {
    return group;
  }
  final all = group.all.any(_hasSelection)
      ? [
          for (final proxy in group.all)
            _hasSelection(proxy) ? proxy.copyWith(now: '') : proxy,
        ]
      : group.all;
  return group.copyWith(now: '', all: all);
}

bool _hasSelection(Proxy proxy) => proxy.now?.isNotEmpty ?? false;

@riverpod
ProxyState proxyState(Ref ref) {
  final suspend = ref.watch(suspendProvider);
  final isStart = ref.watch(runTimeProvider.select((state) => state != null));
  final systemProxySelector = ref.watch(
    networkSettingProvider.select(
      (state) => SystemProxySelectorState(
        systemProxy: state.systemProxy,
        bypassDomain: state.bypassDomain,
      ),
    ),
  );
  final mixedPort = ref.watch(
    patchClashConfigProvider.select((state) => state.mixedPort),
  );
  return ProxyState(
    isStart: suspend ? false : isStart,
    systemProxy: systemProxySelector.systemProxy,
    bassDomain: systemProxySelector.bypassDomain,
    port: mixedPort,
  );
}

@riverpod
ProxiesActionsState proxiesActionsState(Ref ref) {
  final pageLabel = ref.watch(currentPageLabelProvider);
  final hasProviders = ref.watch(
    providersProvider.select((state) => state.isNotEmpty),
  );
  final type = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.type),
  );
  return ProxiesActionsState(
    pageLabel: pageLabel,
    hasProviders: hasProviders,
    type: type,
  );
}

/// Watching the delay map instead would drop nodes one probe at a time, and
/// reading it on any other rebuild would drop them whenever something
/// unrelated changed mid-test.
@riverpod
DelayMap delaysAtLastTestBatch(Ref ref) {
  ref.watch(sortNumProvider);
  ref.listen(delayDataSourceProvider.select((state) => state.isEmpty), (
    _,
    isEmpty,
  ) {
    if (isEmpty) ref.invalidateSelf();
  });
  final delayDataSource = ref.read(delayDataSourceProvider);
  if (delayDataSource.isEmpty) {
    return const {};
  }
  return delayDataSource;
}

@riverpod
GroupsState visibleGroupsState(Ref ref) {
  final currentGroups = ref.watch(currentGroupsStateProvider);
  final hideTimeoutProxies = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.hideTimeoutProxies),
  );
  if (!hideTimeoutProxies) {
    return currentGroups;
  }
  return currentGroups.copyWith(
    value: computeHideTimeout(
      groups: currentGroups.value,
      allGroups: ref.watch(groupsProvider),
      delayMap: ref.watch(delaysAtLastTestBatchProvider),
      selectedMap: ref.watch(selectedMapProvider),
      defaultTestUrl: ref.watch(realTestUrlProvider()),
    ),
  );
}

@riverpod
GroupsState filterGroupsState(Ref ref, String query) {
  final currentGroups = ref.watch(visibleGroupsStateProvider);
  final searchQuery = SearchQuery(query);
  if (searchQuery.isEmpty) {
    return currentGroups;
  }
  final groups = <Group>[];
  for (final group in currentGroups.value) {
    final visible = <Proxy>[];
    for (final proxy in group.all) {
      final text = _proxySearchTexts[proxy] ??= SearchQuery.textOf(
        proxy.searchFields,
      );
      if (searchQuery.matchesText(text)) {
        visible.add(proxy);
      }
    }
    if (visible.isEmpty) {
      continue;
    }
    groups.add(
      visible.length == group.all.length ? group : group.copyWith(all: visible),
    );
  }
  return currentGroups.copyWith(value: groups);
}

@riverpod
ProxiesListState proxiesListState(Ref ref) {
  final query = ref.watch(queryProvider(QueryTag.proxies));
  final currentGroups = ref.watch(filterGroupsStateProvider(query));
  final currentUnfoldSet = ref.watch(unfoldSetProvider);
  final cardType = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.cardType),
  );
  return ProxiesListState(
    groups: currentGroups.value,
    currentUnfoldSet: currentUnfoldSet,
    proxyCardType: cardType,
  );
}

@riverpod
ProxiesTabState proxiesTabState(Ref ref) {
  final query = ref.watch(queryProvider(QueryTag.proxies));
  final currentGroups = ref.watch(filterGroupsStateProvider(query));
  final currentGroupName = ref.watch(
    currentProfileProvider.select((state) => state?.currentGroupName),
  );
  final cardType = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.cardType),
  );
  return ProxiesTabState(
    groups: currentGroups.value,
    currentGroupName: currentGroupName,
    proxyCardType: cardType,
  );
}

@riverpod
bool isStart(Ref ref) {
  return ref.watch(runTimeProvider.select((state) => state != null));
}

@riverpod
ProxiesTabControllerState proxiesTabControllerState(Ref ref) {
  return ref.watch(
    proxiesTabStateProvider.select(
      (state) => ProxiesTabControllerState(
        groupNames: state.groups.map((group) => group.name).toList(),
        currentGroupName: state.currentGroupName,
      ),
    ),
  );
}

@riverpod
ProxyGroupSelectorState proxyGroupSelectorState(
  Ref ref,
  String groupName,
  String query,
) {
  final sortType = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.sortType),
  );
  final cardType = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.cardType),
  );
  final group = ref.watch(
    visibleGroupsStateProvider.select(
      (state) => state.value.getGroup(groupName),
    ),
  );
  final sortNum = ref.watch(sortNumProvider);
  final proxies =
      group?.all
          .whereMatches(SearchQuery(query), (proxy) => proxy.searchFields)
          .toList() ??
      [];
  return ProxyGroupSelectorState(
    testUrl: group?.testUrl,
    proxiesSortType: sortType,
    proxyCardType: cardType,
    sortNum: sortNum,
    groupType: group?.type ?? GroupType.Selector,
    proxies: proxies,
  );
}

@riverpod
String realTestUrl(Ref ref, [String? testUrl]) {
  final currentTestUrl = ref.watch(appSettingProvider).testUrl;
  return testUrl.takeFirstValid([currentTestUrl]);
}

@riverpod
int? delay(Ref ref, {required String proxyName, String? testUrl}) {
  final currentTestUrl = ref.watch(realTestUrlProvider(testUrl));
  final proxyState = ref.watch(realSelectedProxyStateProvider(proxyName));
  final effectiveTestUrl = proxyState.testUrl.takeFirstValid([currentTestUrl]);
  final effectiveProxyName = proxyState.proxyName;
  return ref.watch(
    delayDataSourceProvider.select(
      (state) => state[effectiveTestUrl]?[effectiveProxyName],
    ),
  );
}

@riverpod
DelayTestPhase? delayTestPhase(
  Ref ref, {
  required String proxyName,
  String? testUrl,
}) {
  final currentTestUrl = ref.watch(realTestUrlProvider(testUrl));
  final proxyState = ref.watch(realSelectedProxyStateProvider(proxyName));
  final effectiveTestUrl = proxyState.testUrl.takeFirstValid([currentTestUrl]);
  final key = delayTestKey(effectiveTestUrl, proxyState.proxyName);
  return ref.watch(pendingDelayTestsProvider.select((state) => state[key]));
}

final delayViewProvider = Provider.autoDispose
    .family<
      ({int? delay, DelayTestPhase? phase}),
      ({String proxyName, String? testUrl})
    >((ref, args) {
      final currentTestUrl = ref.watch(realTestUrlProvider(args.testUrl));
      final proxyState = ref.watch(
        realSelectedProxyStateProvider(args.proxyName),
      );
      final effectiveTestUrl = proxyState.testUrl.takeFirstValid([
        currentTestUrl,
      ]);
      final effectiveProxyName = proxyState.proxyName;
      final key = delayTestKey(effectiveTestUrl, effectiveProxyName);
      return (
        delay: ref.watch(
          delayDataSourceProvider.select(
            (state) => state[effectiveTestUrl]?[effectiveProxyName],
          ),
        ),
        phase: ref.watch(
          pendingDelayTestsProvider.select((state) => state[key]),
        ),
      );
    });

@riverpod
Map<String, String> selectedMap(Ref ref) {
  final selectedMap = ref.watch(
    currentProfileProvider.select((state) => state?.selectedMap ?? {}),
  );
  return selectedMap;
}

@riverpod
Set<String> unfoldSet(Ref ref) {
  final unfoldSet = ref.watch(
    currentProfileProvider.select((state) => state?.unfoldSet ?? {}),
  );
  return unfoldSet;
}

@riverpod
SelectedProxyState realSelectedProxyState(Ref ref, String proxyName) {
  final groups = ref.watch(groupsProvider);
  final selectedMap = ref.watch(selectedMapProvider);
  return computeRealSelectedProxyState(
    proxyName,
    groups: groups,
    groupsByName: groupsByNameFor(groups),
    selectedMap: selectedMap,
  );
}

@riverpod
String? proxyName(Ref ref, String groupName) {
  final proxyName = ref.watch(
    selectedMapProvider.select((state) => state[groupName]),
  );
  return proxyName;
}

@riverpod
String? selectedProxyName(Ref ref, String groupName) {
  final proxyName = ref.watch(proxyNameProvider(groupName));
  final group = ref.watch(
    groupsProvider.select((state) => state.getGroup(groupName)),
  );
  return group?.getCurrentSelectedName(proxyName ?? '');
}

final _proxySearchTexts = Expando<String>('proxySearchTexts');

@riverpod
String proxyDesc(Ref ref, ({String name, String type}) proxy) {
  if (!GroupTypeExtension.valueSet.contains(proxy.type)) {
    return proxy.type;
  }
  final group = ref.watch(
    groupsProvider.select((state) => groupsByNameFor(state)[proxy.name]),
  );
  if (group == null) return proxy.type;
  final state = ref.watch(realSelectedProxyStateProvider(proxy.name));
  return "${proxy.type}(${state.proxyName.isNotEmpty ? state.proxyName : '*'})";
}

@riverpod
({bool isProxies, int sortNum, ProxiesSortType sortType}) needUpdateGroups(
  Ref ref,
) {
  final isProxies = ref.watch(
    currentPageLabelProvider.select((state) => state == PageLabel.proxies),
  );
  final sortNum = ref.watch(sortNumProvider);
  final sortType = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.sortType),
  );
  return (isProxies: isProxies, sortNum: sortNum, sortType: sortType);
}
