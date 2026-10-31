import 'dart:typed_data';

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
  SelectedProxyState realStateFor(String proxyName) {
    return realStateCache[proxyName] ??= computeRealSelectedProxyState(
      proxyName,
      groups: groups,
      groupsByName: groupsByName,
      selectedMap: selectedMap,
      cache: realStateCache,
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
    final count = proxies.length;
    final delays = Int64List(count);
    for (var index = 0; index < count; index++) {
      final realState = realStateFor(proxies[index].name);
      final stateTestUrl = realState.testUrl.takeFirstValid([testUrl]);
      delays[index] = delayMap[stateTestUrl]?[realState.proxyName] ?? 0;
    }

    int compareDelayStates(int left, int right) {
      final leftDelay = delays[left];
      final rightDelay = delays[right];
      final leftPriority = leftDelay > 0
          ? 0
          : leftDelay < 0
          ? 1
          : 2;
      final rightPriority = rightDelay > 0
          ? 0
          : rightDelay < 0
          ? 1
          : 2;
      if (leftPriority != rightPriority) {
        return leftPriority.compareTo(rightPriority);
      }
      if (leftDelay != rightDelay) {
        return leftDelay.compareTo(rightDelay);
      }
      return left.compareTo(right);
    }

    var ordered = true;
    for (var index = 1; index < count; index++) {
      if (compareDelayStates(index - 1, index) > 0) {
        ordered = false;
        break;
      }
    }
    if (ordered) {
      return proxies;
    }
    // Ties keep their configured position instead of reshuffling each batch.
    final order = List<int>.generate(count, (index) => index)
      ..sort(compareDelayStates);
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
        cache: realStates,
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

SelectedProxyState computeRealSelectedProxyState(
  String proxyName, {
  required List<Group> groups,
  Map<String, Group>? groupsByName,
  required Map<String, String> selectedMap,
  Map<String, SelectedProxyState>? cache,
}) {
  return _resolveRealSelectedProxyState(
    SelectedProxyState(proxyName: proxyName),
    cache ??= {},
    groups: groups,
    groupsByName: groupsByName,
    selectedMap: selectedMap,
  );
}

SelectedProxyState _resolveRealSelectedProxyState(
  SelectedProxyState state,
  Map<String, SelectedProxyState> cache, {
  required List<Group> groups,
  Map<String, Group>? groupsByName,
  required Map<String, String> selectedMap,
}) {
  if (state.proxyName.isEmpty) return state;
  final cached = cache[state.proxyName];
  if (cached != null) return cached;
  final groupIndex = groupsByName ?? _indexGroups(groups);
  final group = groupIndex[state.proxyName];
  final newState = state.copyWith(group: true);
  if (group == null) {
    return cache[state.proxyName] = newState;
  }
  final currentSelectedName = group.getCurrentSelectedName(
    selectedMap[newState.proxyName] ?? '',
  );
  if (currentSelectedName.isEmpty) {
    return cache[state.proxyName] = newState;
  }
  final resolved = _resolveRealSelectedProxyState(
    newState.copyWith(proxyName: currentSelectedName, testUrl: group.testUrl),
    cache,
    groups: groups,
    groupsByName: groupIndex,
    selectedMap: selectedMap,
  );
  return cache[state.proxyName] = resolved;
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
