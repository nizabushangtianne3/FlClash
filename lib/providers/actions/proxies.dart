part of '../action.dart';

class _DelayTestTarget {
  const _DelayTestTarget({
    required this.proxyName,
    required this.testUrl,
    required this.key,
  });

  final String proxyName;
  final String testUrl;
  final String key;
}

typedef _DelayTestBatch = ({List<Proxy> proxies, String? testUrl});

class _DelayTestJob {
  _DelayTestJob(Iterable<String> keys) : held = keys.toSet();

  final Set<String> held;
  final Set<String> startedOnDispatch = {};
  bool cancelled = false;
}

@Riverpod(keepAlive: true)
class ProxiesAction extends _$ProxiesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  final TaskPool _delayTestPool = TaskPool(maxConcurrentDelayTests);

  final List<_DelayTestJob> _delayTestJobs = [];

  final Map<String, Delay> _bufferedDelays = {};

  final Map<String, Future<Delay?>> _delayTestFutures = {};

  final List<String> _bufferedStarts = [];

  final List<String> _bufferedFinishes = [];

  Timer? _delayFlushTimer;

  final Map<String, String> _pendingSelectedRollback = {};
  final Map<String, String> _appliedSelected = {};
  final Map<String, int> _appliedSelectedIntent = {};
  final Map<String, int> _selectedIntent = {};
  final Map<String, Set<int>> _activeSelectedIntents = {};
  Future<void>? _connectionCleanup;

  @override
  void build() {
    ref.onDispose(() => _delayFlushTimer?.cancel());
    ref.listen(coreStatusProvider, (_, next) {
      if (next != CoreStatus.connected) {
        cancelDelayTests();
      }
    });
  }

  void cancelDelayTests() {
    for (final job in _delayTestJobs) {
      job.cancelled = true;
      job.held.clear();
    }
    _delayFlushTimer?.cancel();
    _delayFlushTimer = null;
    _bufferedDelays.clear();
    _delayTestFutures.clear();
    _bufferedStarts.clear();
    _bufferedFinishes.clear();
    ref.read(pendingDelayTestsProvider.notifier).clear();
  }

  void _scheduleDelayFlush() {
    _delayFlushTimer ??= Timer(renderThrottleDuration, _flushDelayResults);
  }

  void _flushDelayResults() {
    _delayFlushTimer?.cancel();
    _delayFlushTimer = null;
    if (_bufferedDelays.isNotEmpty) {
      final delays = _bufferedDelays.values.toList(growable: false);
      _bufferedDelays.clear();
      ref.read(delayDataSourceProvider.notifier).setDelays(delays);
    }
    if (_bufferedStarts.isNotEmpty || _bufferedFinishes.isNotEmpty) {
      final started = List.of(_bufferedStarts);
      final finished = List.of(_bufferedFinishes);
      _bufferedStarts.clear();
      _bufferedFinishes.clear();
      ref
          .read(pendingDelayTestsProvider.notifier)
          .apply(started: started, finished: finished);
    }
  }

  void updateGroupsDebounce([Duration? duration]) {
    debouncer.call(FunctionTag.updateGroups, updateGroups, duration: duration);
  }

  void changeProxyDebounce(String groupName, String proxyName) {
    final intent = _beginSelectedIntent(groupName);
    _pendingSelectedRollback.putIfAbsent(
      groupName,
      () => _currentSelectedName(groupName),
    );
    ref
        .read(profilesActionProvider.notifier)
        .updateCurrentSelectedMap(groupName, proxyName);
    // Keep the wait short so a dead node does not feel laggy when the user
    // rapidly picks a replacement; 150ms still coalesces double-taps.
    debouncer.call(
      (FunctionTag.changeProxy, groupName),
      (String groupName, String proxyName) async {
        await changeProxy(
          groupName: groupName,
          proxyName: proxyName,
          intent: intent,
        );
      },
      args: [groupName, proxyName],
      duration: const Duration(milliseconds: 150),
    );
  }

  int _beginSelectedIntent(String groupName) {
    return _selectedIntent.update(
      groupName,
      (intent) => intent + 1,
      ifAbsent: () => 1,
    );
  }

  bool _isLatestSelectedIntent(String groupName, int intent) {
    return _selectedIntent[groupName] == intent;
  }

  String _currentSelectedName(String groupName) {
    return ref.read(currentProfileProvider)?.selectedMap[groupName] ?? '';
  }

  Future<void> updateGroups() async {
    try {
      final sortType = ref.read(
        proxiesStyleSettingProvider.select((state) => state.sortType),
      );
      final delayMap = ref.read(delayDataSourceProvider);
      final testUrl = ref.read(
        appSettingProvider.select((state) => state.testUrl),
      );
      final selectedMap = ref.read(
        currentProfileProvider.select((state) => state?.selectedMap ?? {}),
      );
      final next = await retry(
        task: () async {
          try {
            return await _core.getProxiesGroups(
              selectedMap: selectedMap,
              sortType: sortType,
              delayMap: delayMap,
              defaultTestUrl: testUrl,
            );
          } catch (e) {
            commonPrint.log(
              'updateGroups error: $e',
              logLevel: coreFailureLogLevel(e),
            );
            return [];
          }
        },
        retryIf: (res) => res.isEmpty,
      );
      // Isolate rebuild + provider fan-out is expensive; skip when unchanged.
      ref.read(groupsProvider.notifier).update((_) => next);
    } catch (e) {
      // The Core failure path already runs inside the retry task above; a
      // throw here only means ref.read hit a disposed container or the
      // groupsProvider write itself failed.
      commonPrint.log(
        'updateGroups failed: $e',
        logLevel: coreFailureLogLevel(e),
      );
    }
  }

  void updateCurrentGroupName(String groupName) {
    final profile = ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(currentGroupName: groupName));
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(unfoldSet: value));
  }

  void setDelay(Delay delay) {
    _bufferedDelays[delayTestKey(delay.url, delay.name)] = delay;
    _scheduleDelayFlush();
  }

  Future<bool> changeProxy({
    required String groupName,
    required String proxyName,
    int? intent,
  }) async {
    final selectedIntent = intent ?? _beginSelectedIntent(groupName);
    final activeIntents = _activeSelectedIntents.putIfAbsent(
      groupName,
      () => {},
    );
    activeIntents.add(selectedIntent);
    _pendingSelectedRollback.putIfAbsent(
      groupName,
      () => _currentSelectedName(groupName),
    );
    final profilesAction = ref.read(profilesActionProvider.notifier);
    profilesAction.updateCurrentSelectedMap(groupName, proxyName);
    try {
      final result = await _core.changeProxy(
        ChangeProxyParams(groupName: groupName, proxyName: proxyName),
      );
      if (result.message.isNotEmpty) {
        throw MessageException(result.message);
      }
      if (!result.changed) {
        return false;
      }
      final isNewestApplied =
          selectedIntent > (_appliedSelectedIntent[groupName] ?? 0);
      if (isNewestApplied) {
        _appliedSelected[groupName] = proxyName;
        _appliedSelectedIntent[groupName] = selectedIntent;
      }
      final hasNewerIntent = activeIntents.any(
        (active) => active > selectedIntent,
      );
      if (isNewestApplied && !hasNewerIntent) {
        _pendingSelectedRollback.remove(groupName);
        _patchSelectedProxy(groupName, proxyName);
      }
      unawaited(_runConnectionCleanup());
      return true;
    } catch (error) {
      if (!_isLatestSelectedIntent(groupName, selectedIntent)) {
        return false;
      }
      final rollbackName =
          _appliedSelected[groupName] ??
          _pendingSelectedRollback.remove(groupName) ??
          _currentSelectedName(groupName);
      commonPrint.log(
        'changeProxy($groupName -> $proxyName) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
      profilesAction.updateCurrentSelectedMap(groupName, rollbackName);
      dialogs.showNotifier(
        currentAppLocalizations.changeProxyFailedTip,
        level: MessageLevel.error,
      );
      return false;
    } finally {
      activeIntents.remove(selectedIntent);
      if (activeIntents.isEmpty) {
        _activeSelectedIntents.remove(groupName);
      }
    }
  }

  Future<void> _runConnectionCleanup() {
    final previous = _connectionCleanup;
    final task = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // The previous task already logged its own failure.
        }
      }
      try {
        if (ref.read(appSettingProvider).closeConnections) {
          await _core.closeConnections();
        } else {
          await _core.resetConnections();
        }
      } catch (error) {
        commonPrint.log(
          'changeProxy connection cleanup failed: $error',
          logLevel: coreFailureLogLevel(error),
        );
      }
    }();
    _connectionCleanup = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_connectionCleanup, task)) {
          _connectionCleanup = null;
        }
      }),
    );
    return task;
  }

  void _patchSelectedProxy(String groupName, String proxyName) {
    final groups = ref.read(groupsProvider);
    if (groups.isEmpty) {
      return;
    }
    ref
        .read(groupsProvider.notifier)
        .update(
          (list) => [
            for (final group in list)
              if (group.name == groupName)
                group.copyWith(now: proxyName)
              else
                group,
          ],
        );
    _core.patchCachedGroupNow(groupName, proxyName);
  }

  Future<String> updateProvider(
    ExternalProvider provider, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      final clashProvidersAction = ref.read(
        clashProvidersActionProvider.notifier,
      );
      final ruleSet = await clashProvidersAction.remoteProviderOf(provider);
      if (ruleSet != null && !await clashProvidersAction.syncRemote(ruleSet)) {
        return '';
      }
      final message = await _core.updateExternalProvider(
        providerName: provider.name,
      );
      if (message.isNotEmpty) return message;
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
      return '';
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<String> sideLoadExternalProvider(
    ExternalProvider provider,
    String data, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      final message = await _core.sideLoadExternalProvider(
        providerName: provider.name,
        data: data,
      );
      if (message.isNotEmpty) return message;
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
      return '';
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<void> proxyDelayTest(Proxy proxy, [String? testUrl]) {
    return _runDelayTests([
      (proxies: [proxy], testUrl: testUrl),
    ], priority: true);
  }

  Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) async {
    await _runDelayTests([(proxies: proxies, testUrl: testUrl)]);
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTestGroups(List<Group> groups) async {
    await _runDelayTests([
      for (final group in groups) (proxies: group.all, testUrl: group.testUrl),
    ]);
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTestPageGroup(
    String groupName, {
    bool matchSearch = true,
  }) async {
    final group = ref.read(groupsProvider).getGroup(groupName);
    if (group == null) {
      return;
    }
    final testing = ref.read(delayTestingGroupsProvider.notifier);
    if (!testing.start(groupName)) {
      return;
    }
    try {
      final query = SearchQuery(
        matchSearch ? ref.read(queryProvider(QueryTag.proxies)) : '',
      );
      await _runDelayTests([
        (
          proxies: group.all
              .whereMatches(query, (proxy) => proxy.searchFields)
              .toList(),
          testUrl: group.testUrl,
        ),
      ], priority: true);
      ref.read(sortNumProvider.notifier).add();
    } finally {
      testing.stop(groupName);
    }
  }

  List<_DelayTestTarget> _resolveDelayTestTargets(
    List<_DelayTestBatch> batches,
  ) {
    final groups = ref.read(groupsProvider);
    final groupsByName = <String, Group>{};
    for (final group in groups) {
      groupsByName.putIfAbsent(group.name, () => group);
    }
    final realStates = <String, SelectedProxyState>{};
    final selectedMap = ref.read(
      currentProfileProvider.select((state) => state?.selectedMap ?? {}),
    );
    final seen = <String>{};
    final targets = <_DelayTestTarget>[];
    for (final batch in batches) {
      final fallbackTestUrl = ref.read(realTestUrlProvider(batch.testUrl));
      for (final proxy in batch.proxies) {
        final state = realStates.putIfAbsent(
          proxy.name,
          () => computeRealSelectedProxyState(
            proxy.name,
            groups: groups,
            groupsByName: groupsByName,
            selectedMap: selectedMap,
          ),
        );
        if (state.proxyName.isEmpty) {
          continue;
        }
        final currentTestUrl = state.testUrl.takeFirstValid([fallbackTestUrl]);
        final key = delayTestKey(currentTestUrl, state.proxyName);
        if (!seen.add(key)) {
          continue;
        }
        targets.add(
          _DelayTestTarget(
            proxyName: state.proxyName,
            testUrl: currentTestUrl,
            key: key,
          ),
        );
      }
    }
    return targets;
  }

  Future<void> _runDelayTests(
    List<_DelayTestBatch> batches, {
    bool priority = false,
  }) async {
    final targets = _resolveDelayTestTargets(batches);
    if (targets.isEmpty) {
      return;
    }
    final pending = ref.read(pendingDelayTestsProvider.notifier);
    final job = _DelayTestJob(targets.map((target) => target.key));
    _delayTestJobs.add(job);
    // TaskPool.run starts a task synchronously while it has an idle slot.
    job.startedOnDispatch.addAll(
      targets.take(_delayTestPool.idleSlots).map((target) => target.key),
    );
    pending.apply(acquired: job.held, started: job.startedOnDispatch);
    try {
      await Future.wait(
        targets.map(
          (target) => _delayTestPool.run(
            () => _runDelayTest(job, target),
            priority: priority,
          ),
        ),
      );
    } finally {
      _delayTestJobs.remove(job);
      _flushDelayResults();
      final abandoned = job.held.toList();
      job.held.clear();
      pending.apply(
        finished: abandoned.where(job.startedOnDispatch.contains),
        released: abandoned.where(
          (key) => !job.startedOnDispatch.contains(key),
        ),
      );
    }
  }

  Future<void> _runDelayTest(_DelayTestJob job, _DelayTestTarget target) async {
    if (job.cancelled) {
      return;
    }
    if (!job.startedOnDispatch.contains(target.key)) {
      _bufferedStarts.add(target.key);
      _scheduleDelayFlush();
    }
    try {
      final delay = await _runCoreDelayTest(target);
      if (delay != null && !job.cancelled) {
        setDelay(delay);
      }
    } catch (error) {
      if (error is CoreMethodException && error.isCoreUnavailable) {
        job.cancelled = true;
      }
      commonPrint.log(
        'Delay test failed for ${target.proxyName}: $error',
        logLevel: coreFailureLogLevel(error),
      );
    } finally {
      if (job.held.remove(target.key)) {
        _bufferedFinishes.add(target.key);
        _scheduleDelayFlush();
      }
    }
  }

  Future<Delay?> _runCoreDelayTest(_DelayTestTarget target) {
    final active = _delayTestFutures[target.key];
    if (active != null) {
      return active;
    }
    late final Future<Delay?> future;
    future = _core.getDelay(target.testUrl, target.proxyName).whenComplete(() {
      if (identical(_delayTestFutures[target.key], future)) {
        _delayTestFutures.remove(target.key);
      }
    });
    return _delayTestFutures[target.key] = future;
  }
}
