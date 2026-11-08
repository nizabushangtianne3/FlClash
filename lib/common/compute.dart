import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

/// A test url nobody measured answers no delay for any name.
const _noDelays = <String, int?>{};

int _delaySortPriority(int delay) => switch (delay) {
  > 0 => 0,
  0 => 1,
  delayTimedOutValue => 2,
  _ => 3,
};

// Delay sort packs per-proxy state: low 2 bits are priority, group bit marks a
// nested group.
const _priorityMask = 0x03;
const _groupFlag = 0x04;

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

  List<Proxy> sortOfDelay(List<Proxy> proxies, String testUrl) {
    final fallbackDelays = delayMap[testUrl];
    final count = proxies.length;
    final delays = Int64List(count);
    final flags = Uint8List(count);
    for (var index = 0; index < count; index++) {
      final proxyName = proxies[index].name;
      // A proxy that is not a group resolves to itself: its delay is the one
      // measured for its own name under the group's test url.
      final realState = groupsByName[proxyName] == null
          ? null
          : realStateFor(proxyName);
      final delay = realState == null
          ? (fallbackDelays ?? _noDelays)[proxyName] ?? 0
          : (delayMap[realState.testUrl.takeFirstValid([testUrl])] ??
                    _noDelays)[realState.proxyName] ??
                0;
      delays[index] = delay;
      flags[index] =
          _delaySortPriority(delay) |
          (realState?.group == true ? _groupFlag : 0);
    }

    int compareDelayStates(int left, int right) {
      final leftDelay = delays[left];
      final rightDelay = delays[right];
      final leftFlags = flags[left];
      final rightFlags = flags[right];
      final leftPriority = leftFlags & _priorityMask;
      final rightPriority = rightFlags & _priorityMask;
      if (leftPriority != rightPriority) {
        return leftPriority.compareTo(rightPriority);
      }
      if (leftDelay != rightDelay) {
        return leftDelay.compareTo(rightDelay);
      }
      final leftGroup = leftFlags & _groupFlag;
      final rightGroup = rightFlags & _groupFlag;
      if (leftGroup != rightGroup) {
        return rightGroup.compareTo(leftGroup);
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
      group.all,
      group.testUrl.takeFirstValid([defaultTestUrl]),
    );
  });
}

List<Group> _sortGroups(
  List<Group> groups,
  List<Proxy> Function(Group group) sortAll,
) {
  List<Group>? sortedGroups;
  for (var index = 0; index < groups.length; index++) {
    final group = groups[index];
    final next = group.all.length <= 1
        ? group
        : _withSortedAll(group, sortAll(group));
    if (identical(next, group)) {
      continue;
    }
    sortedGroups ??= List.of(groups, growable: true);
    sortedGroups[index] = next;
  }
  return sortedGroups ?? groups;
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

final _trayProxiesByName = Expando<Map<String, Proxy>>();

List<Proxy> visibleTrayProxies(Group group, String? selectedName) {
  final all = group.all;
  if (all.length <= maxTrayProxiesPerGroup) {
    return all;
  }

  final String? wanted = selectedName;
  final others = <Proxy>[];
  Proxy? selected;
  if (wanted != null) {
    // A group is immutable, so a name index survives the next tray refresh.
    selected = (_trayProxiesByName[group] ??= {
      for (final proxy in all) proxy.name: proxy,
    })[wanted];
  }
  final limit = maxTrayProxiesPerGroup - (selected == null ? 0 : 1);
  for (final proxy in all) {
    if (proxy.name == wanted) {
      continue;
    }
    if (others.length >= limit) {
      break;
    }
    others.add(proxy);
  }
  return selected == null ? others : [selected, ...others];
}

final _groupsByNameCache = Expando<Map<String, Group>>();

Map<String, Group> groupsByNameFor(List<Group> allGroups) {
  return _groupsByNameCache[allGroups] ??= _indexGroups(allGroups);
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
  List<Group>? nextGroups;
  for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    final group = groups[groupIndex];
    final groupTestUrl = group.testUrl.takeFirstValid([defaultTestUrl]);
    final groupWithNow = groupsByName[group.name] ?? group;
    final delays = delayMap[groupTestUrl];
    final selectedName = _coreSelectedName(
      groupWithNow,
      selectedMap[group.name] ?? '',
    );

    bool keeps(Proxy proxy) {
      // A group's delay is its pick's, and hiding it would take away the only
      // way to choose the group where the mode does not show it on its own.
      if (proxy.name == selectedName || groupsByName.containsKey(proxy.name)) {
        return true;
      }
      // What reaches here is not a group, so it resolves to itself: the delay
      // measured for its own name under the group's test url is its own.
      if (_unprobeableProxyTypes.contains(proxy.type)) {
        return true;
      }
      final delay = delays?[proxy.name];
      return delay == null || delay > 0;
    }

    List<Proxy>? visible;
    for (var index = 0; index < group.all.length; index++) {
      if (keeps(group.all[index])) {
        visible?.add(group.all[index]);
      } else {
        visible ??= List<Proxy>.of(group.all.sublist(0, index));
      }
    }

    final next = visible == null
        ? group
        : group.copyWith(all: visible.isEmpty ? group.all : visible);
    if (identical(next, group)) {
      continue;
    }
    nextGroups ??= List.of(groups, growable: true);
    nextGroups[groupIndex] = next;
  }
  return nextGroups ?? groups;
}

String _coreSelectedName(Group group, String storedName) {
  if (group.type.isComputedSelected) {
    return group.realNow;
  }
  if (storedName.isNotEmpty && group.containsMemberName(storedName)) {
    return storedName;
  }
  final now = group.realNow;
  return now.isNotEmpty && group.containsMemberName(now) ? now : '';
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
  if (group == null) {
    return cache[state.proxyName] = state;
  }
  final newState = state.copyWith(group: true);
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
