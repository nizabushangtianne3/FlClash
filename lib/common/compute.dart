import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

List<Group> computeSort({
  required List<Group> groups,
  required ProxiesSortType sortType,
  required DelayMap delayMap,
  required Map<String, String> selectedMap,
  required String defaultTestUrl,
}) {
  // none: preserve group and member list identity for Riverpod equality.
  if (sortType == ProxiesSortType.none) {
    return groups;
  }

  final groupsByName = {for (final group in groups) group.name: group};
  final realStateCache = <String, SelectedProxyState>{};
  SelectedProxyState realStateFor(String proxyName) {
    return realStateCache.putIfAbsent(
      proxyName,
      () => computeRealSelectedProxyState(
        proxyName,
        groups: groups,
        groupsByName: groupsByName,
        selectedMap: selectedMap,
      ),
    );
  }

  List<Proxy> sortOfDelay({
    required List<Group> groups,
    required List<Proxy> proxies,
    required DelayMap delayMap,
    required Map<String, String> selectedMap,
    required String testUrl,
  }) {
    final delayStates = {
      for (final proxy in proxies)
        proxy.name: computeProxyDelayState(
          proxyName: proxy.name,
          testUrl: testUrl,
          groups: groups,
          selectedMap: selectedMap,
          delayMap: delayMap,
          groupsByName: groupsByName,
          realState: realStateFor(proxy.name),
        ),
    };
    final sorted =
        List.of(proxies)
          ..sort((a, b) => delayStates[a.name]!.compareTo(delayStates[b.name]!));
    return _sameOrder(sorted, proxies) ? proxies : sorted;
  }

  List<Proxy> sortOfName(List<Proxy> proxies) {
    final sorted = List.of(proxies)..sort((a, b) => a.name.compareTo(b.name));
    return _sameOrder(sorted, proxies) ? proxies : sorted;
  }

  final sortedGroups = [
    for (final group in groups)
      if (group.all.length <= 1)
        group
      else
        () {
          final List<Proxy> sortedAll = switch (sortType) {
            ProxiesSortType.none => group.all,
            ProxiesSortType.delay => sortOfDelay(
              groups: groups,
              proxies: group.all,
              delayMap: delayMap,
              selectedMap: selectedMap,
              testUrl: group.testUrl.takeFirstValid([defaultTestUrl]),
            ),
            ProxiesSortType.name => sortOfName(group.all),
          };
          return _withSortedAll(group, sortedAll);
        }(),
  ];
  return _sameGroups(sortedGroups, groups) ? groups : sortedGroups;
}

Group _withSortedAll(Group group, List<Proxy> sorted) {
  return _sameOrder(sorted, group.all) ? group : group.copyWith(all: sorted);
}

bool _sameOrder(List<Proxy> sorted, List<Proxy> proxies) {
  for (var i = 0; i < proxies.length; i++) {
    if (sorted[i].name != proxies[i].name) return false;
  }
  return true;
}

bool _sameGroups(List<Group> sorted, List<Group> groups) {
  for (var i = 0; i < groups.length; i++) {
    if (sorted[i] != groups[i]) return false;
  }
  return true;
}

/// Built-in adapters whose delay probe always fails, so a timeout says nothing.
const _unprobeableProxyTypes = {
  'Reject',
  'RejectDrop',
  'Pass',
  'PassRule',
  'Rematch',
  'Compatible',
  'Dns',
};

Map<String, String>? _proxyTypesCache;
List<Group>? _proxyTypesSource;

Map<String, String> _proxyTypesFor(List<Group> allGroups) {
  if (identical(allGroups, _proxyTypesSource) && _proxyTypesCache != null) {
    return _proxyTypesCache!;
  }
  _proxyTypesSource = allGroups;
  return _proxyTypesCache = {
    for (final group in allGroups)
      for (final proxy in group.all) proxy.name: proxy.type,
  };
}

List<Group> computeHideTimeout({
  required List<Group> groups,
  required List<Group> allGroups,
  required DelayMap delayMap,
  required Map<String, String> selectedMap,
  required String defaultTestUrl,
}) {
  final realStates = <String, SelectedProxyState>{};
  final groupsByName = {for (final group in allGroups) group.name: group};
  final proxyTypes = _proxyTypesFor(allGroups);
  return groups.map((group) {
    final groupTestUrl = group.testUrl.takeFirstValid([defaultTestUrl]);
    final groupWithNow = groupsByName[group.name] ?? group;
    final selectedName = groupWithNow.getCurrentSelectedName(
      selectedMap[group.name] ?? '',
    );
    final visible = group.all.where((proxy) {
      if (proxy.name == selectedName) {
        return true;
      }
      final state = realStates.putIfAbsent(
        proxy.name,
        () => computeRealSelectedProxyState(
          proxy.name,
          groups: allGroups,
          selectedMap: selectedMap,
          groupsByName: groupsByName,
        ),
      );
      if (_unprobeableProxyTypes.contains(proxyTypes[state.proxyName])) {
        return true;
      }
      final testUrl = state.testUrl.takeFirstValid([groupTestUrl]);
      final delay = delayMap[testUrl]?[state.proxyName];
      return delay == null || delay > 0;
    }).toList();
    return group.copyWith(all: visible.isEmpty ? group.all : visible);
  }).toList();
}

SelectedProxyState getRealSelectedProxyState(
  SelectedProxyState state, {
  required List<Group> groups,
  required Map<String, String> selectedMap,
  Map<String, Group>? groupsByName,
}) {
  if (state.proxyName.isEmpty) return state;
  final newState = state.copyWith(group: true);
  final group =
      groupsByName?[state.proxyName] ?? groups.getGroup(state.proxyName);
  if (group == null) return newState;
  final currentSelectedName = group.getCurrentSelectedName(
    selectedMap[newState.proxyName] ?? '',
  );
  if (currentSelectedName.isEmpty) {
    return newState;
  }
  return getRealSelectedProxyState(
    newState.copyWith(proxyName: currentSelectedName, testUrl: group.testUrl),
    groups: groups,
    selectedMap: selectedMap,
    groupsByName: groupsByName,
  );
}

SelectedProxyState computeRealSelectedProxyState(
  String proxyName, {
  required List<Group> groups,
  required Map<String, String> selectedMap,
  Map<String, Group>? groupsByName,
}) {
  return getRealSelectedProxyState(
    SelectedProxyState(proxyName: proxyName),
    groups: groups,
    selectedMap: selectedMap,
    groupsByName: groupsByName,
  );
}

String delayTestKey(String testUrl, String proxyName) {
  return '$testUrl\u0000$proxyName';
}

DelayState computeProxyDelayState({
  required String proxyName,
  required String testUrl,
  required List<Group> groups,
  required Map<String, String> selectedMap,
  required DelayMap delayMap,
  Map<String, Group>? groupsByName,
  SelectedProxyState? realState,
}) {
  final state =
      realState ??
      computeRealSelectedProxyState(
        proxyName,
        groups: groups,
        selectedMap: selectedMap,
        groupsByName: groupsByName,
      );
  final currentDelayMap =
      delayMap[state.testUrl.takeFirstValid([testUrl])] ?? {};
  final delay = currentDelayMap[state.proxyName];
  return DelayState(delay: delay ?? 0, group: state.group);
}
