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
  if (sortType == ProxiesSortType.delay && delayMap.isEmpty) {
    return groups;
  }
  if (sortType == ProxiesSortType.name) {
    return _sortGroups(groups, _sortByName);
  }

  final groupsByName = groupsByNameFor(groups);
  final realStateCache = <String, SelectedProxyState>{};
  final delayStateCache = <String, DelayState>{};
  SelectedProxyState realStateFor(String proxyName) {
    return realStateCache[proxyName] ??= computeRealSelectedProxyState(
      proxyName,
      groups: groups,
      groupsByName: groupsByName,
      selectedMap: selectedMap,
    );
  }

  List<Proxy> sortOfDelay({
    required List<Group> groups,
    required List<Proxy> proxies,
    required DelayMap delayMap,
    required Map<String, String> selectedMap,
    required String testUrl,
  }) {
    if (delayMap.isEmpty) {
      return proxies;
    }
    final delayStates = <DelayState>[];
    for (final proxy in proxies) {
      final realState = realStateFor(proxy.name);
      final stateTestUrl = realState.testUrl.takeFirstValid([testUrl]);
      final cacheKey = delayTestKey(stateTestUrl, realState.proxyName);
      delayStates.add(
        delayStateCache[cacheKey] ??= computeProxyDelayState(
          proxyName: proxy.name,
          testUrl: testUrl,
          groups: groups,
          selectedMap: selectedMap,
          delayMap: delayMap,
          groupsByName: groupsByName,
          realState: realState,
        ),
      );
    }
    var ordered = true;
    for (var index = 1; index < proxies.length; index++) {
      final previous = delayStates[index - 1];
      final current = delayStates[index];
      if (previous.compareTo(current) > 0) {
        ordered = false;
        break;
      }
    }
    if (ordered) {
      return proxies;
    }
    // Ties keep their configured position instead of reshuffling each batch.
    final order = List<int>.generate(proxies.length, (index) => index)
      ..sort((a, b) {
        final compared = delayStates[a].compareTo(delayStates[b]);
        return compared != 0 ? compared : a.compareTo(b);
      });
    return [for (final index in order) proxies[index]];
  }

  return _sortGroups(groups, (group) {
    return sortOfDelay(
      groups: groups,
      proxies: group.all,
      delayMap: delayMap,
      selectedMap: selectedMap,
      testUrl: group.testUrl.takeFirstValid([defaultTestUrl]),
    );
  });
}

List<Group> _sortGroups(
  List<Group> groups,
  List<Proxy> Function(Group group) sortAll,
) {
  final sortedGroups = [
    for (final group in groups)
      if (group.all.length <= 1)
        group
      else
        _withSortedAll(group, sortAll(group)),
  ];
  return _sameGroups(sortedGroups, groups) ? groups : sortedGroups;
}

List<Proxy> _sortByName(Group group) {
  final proxies = group.all;
  for (var index = 1; index < proxies.length; index++) {
    if (proxies[index - 1].name.compareTo(proxies[index].name) > 0) {
      return List.of(proxies)..sort((a, b) => a.name.compareTo(b.name));
    }
  }
  return proxies;
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

bool isUnprobeableProxyType(String type) =>
    _unprobeableProxyTypes.contains(type);

List<Proxy> visibleTrayProxies(Group group, String? selectedName) {
  final all = group.all;
  if (all.length <= maxTrayProxiesPerGroup) {
    return all;
  }

  final others = <Proxy>[];
  Proxy? selected;
  for (final proxy in all) {
    if (proxy.name == selectedName) {
      selected = proxy;
    } else if (others.length < maxTrayProxiesPerGroup) {
      others.add(proxy);
    }
  }
  if (selected != null && others.length == maxTrayProxiesPerGroup) {
    others.removeLast();
  }
  return selected == null ? others : [selected, ...others];
}

Map<String, String>? _proxyTypesCache;
List<Group>? _proxyTypesSource;
final _groupsByNameCache = Expando<Map<String, Group>>();

Map<String, Group> groupsByNameFor(List<Group> allGroups) {
  return _groupsByNameCache[allGroups] ??= _indexGroups(allGroups);
}

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
  // Without measured delays nothing can be classified as timed out.
  if (delayMap.isEmpty) {
    return groups;
  }
  final groupsByName = groupsByNameFor(allGroups);
  final realStates = <String, SelectedProxyState>{};
  final proxyTypes = _proxyTypesFor(allGroups);
  return groups.map((group) {
    final groupTestUrl = group.testUrl.takeFirstValid([defaultTestUrl]);
    final groupWithNow = groupsByName[group.name] ?? group;
    final selectedName = groupWithNow.getCurrentSelectedName(
      selectedMap[group.name] ?? '',
    );
    final visible = group.all.where((proxy) {
      // A group's delay is its pick's, and hiding it would take away the only
      // way to choose the group where the mode does not show it on its own.
      if (proxy.name == selectedName || groupsByName.containsKey(proxy.name)) {
        return true;
      }
      final state = realStates[proxy.name] ??= computeRealSelectedProxyState(
        proxy.name,
        groups: allGroups,
        groupsByName: groupsByName,
        selectedMap: selectedMap,
      );
      if (_unprobeableProxyTypes.contains(proxyTypes[state.proxyName])) {
        return true;
      }
      final testUrl = state.testUrl.takeFirstValid([groupTestUrl]);
      final delay = delayMap[testUrl]?[state.proxyName];
      return delay == null || delay > 0;
    }).toList();
    return visible.length == group.all.length && _sameOrder(visible, group.all)
        ? group
        : group.copyWith(all: visible.isEmpty ? group.all : visible);
  }).toList();
}

SelectedProxyState getRealSelectedProxyState(
  SelectedProxyState state, {
  required List<Group> groups,
  Map<String, Group>? groupsByName,
  required Map<String, String> selectedMap,
}) {
  if (state.proxyName.isEmpty) return state;
  final groupIndex = groupsByName ?? _indexGroups(groups);
  final group = groupIndex[state.proxyName];
  final newState = state.copyWith(group: true);
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
    groupsByName: groupIndex,
    selectedMap: selectedMap,
  );
}

SelectedProxyState computeRealSelectedProxyState(
  String proxyName, {
  required List<Group> groups,
  Map<String, Group>? groupsByName,
  required Map<String, String> selectedMap,
}) {
  return getRealSelectedProxyState(
    SelectedProxyState(proxyName: proxyName),
    groups: groups,
    groupsByName: groupsByName,
    selectedMap: selectedMap,
  );
}

Map<String, Group> _indexGroups(List<Group> groups) {
  final indexed = <String, Group>{};
  for (final group in groups) {
    indexed[group.name] ??= group;
  }
  return indexed;
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
        groupsByName: groupsByName,
        selectedMap: selectedMap,
      );
  final currentDelayMap =
      delayMap[state.testUrl.takeFirstValid([testUrl])] ?? {};
  final delay = currentDelayMap[state.proxyName];
  return DelayState(delay: delay ?? 0, group: state.group);
}
