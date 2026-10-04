import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/route_state.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CoreManager extends ConsumerStatefulWidget {
  final Widget child;

  const CoreManager({super.key, required this.child});

  @override
  ConsumerState<CoreManager> createState() => _CoreContainerState();
}

class _CoreContainerState extends ConsumerState<CoreManager>
    with CoreEventListener {
  CoreController get _core => ref.read(coreHandlerProvider);

  Timer? _feedFlushTimer;
  final List<Log> _bufferedLogs = [];
  final List<TrackerInfo> _bufferedRequests = [];
  final List<DnsQuery> _bufferedDns = [];
  int _bufferedRequestCount = 0;
  int _bufferedDnsCount = 0;
  // Cap in-flight buffers so a 400ms flood cannot allocate unbounded lists
  // before the next flush (FixedList still truncates on the provider side).
  static const _maxBufferedLogs = 400;
  static const _maxBufferedRequests = 300;
  static const _maxBufferedDns = 300;

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    coreEventManager.addListener(this);
    ref.read(updatingActionProvider.notifier);
    // A rejected profile stays selected on purpose: silently reverting to
    // the previous one hides the error and looks like the switch was lost.
    ref.listenManual(currentProfileIdProvider, (prev, next) {
      if (prev == next) return;
      runAfterFrame(() {
        unawaited(ref.read(setupActionProvider.notifier).fullSetup());
      });
    });
    ref.listenManual(updateParamsProvider, (prev, next) {
      if (prev != next) {
        ref.read(setupActionProvider.notifier).updateConfigDebounce();
      }
    });
    ref.listenManual(setupPatchProvider, (prev, next) {
      if (prev != next) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      }
    });
    ref.listenManual(appSettingProvider.select((state) => state.openLogs), (
      prev,
      next,
    ) {
      if (prev != next) {
        _syncLogStream();
      }
    });
    // Every Core process starts without a log stream.
    ref.listenManual(coreStatusProvider, (prev, next) {
      if (next == CoreStatus.connected && prev != CoreStatus.connected) {
        _syncLogStream();
      }
    }, fireImmediately: true);
  }

  void _syncLogStream() {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    if (ref.read(appSettingProvider).openLogs) {
      _core.startLog();
    } else {
      _core.stopLog();
    }
  }

  @override
  void dispose() {
    _feedFlushTimer?.cancel();
    _flushFeeds();
    coreEventManager.removeListener(this);
    super.dispose();
  }

  void _scheduleFeedFlush() {
    _feedFlushTimer ??= Timer(renderThrottleDuration, _flushFeeds);
  }

  void _flushFeeds() {
    _feedFlushTimer?.cancel();
    _feedFlushTimer = null;
    if (_bufferedLogs.isNotEmpty) {
      final logs = List<Log>.of(_bufferedLogs);
      _bufferedLogs.clear();
      ref.read(logsProvider.notifier).addAll(logs);
    }
    if (_bufferedRequests.isNotEmpty) {
      final requests = List<TrackerInfo>.of(_bufferedRequests);
      _bufferedRequests.clear();
      ref.read(requestsProvider.notifier).addRequests(requests);
    }
    if (_bufferedDns.isNotEmpty) {
      final queries = List<DnsQuery>.of(_bufferedDns);
      _bufferedDns.clear();
      ref.read(dnsQueriesProvider.notifier).addQueries(queries);
    }
    if (_bufferedRequestCount != 0) {
      final delta = _bufferedRequestCount;
      _bufferedRequestCount = 0;
      ref.read(requestCountProvider.notifier).update((count) => count + delta);
    }
    if (_bufferedDnsCount != 0) {
      final delta = _bufferedDnsCount;
      _bufferedDnsCount = 0;
      ref.read(dnsQueryCountProvider.notifier).update((count) => count + delta);
    }
  }

  @override
  Future<void> onDelay(Delay delay) async {
    super.onDelay(delay);
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    proxiesAction.setDelay(delay);
    // Only delay-based sorting needs a full groups rebuild after probes.
    // none/name order is independent of latency, and hide-timeout uses
    // delaysAtLastTestBatch + sortNum instead.
    debouncer.call(FunctionTag.updateDelay, () async {
      final sortType = ref.read(
        proxiesStyleSettingProvider.select((state) => state.sortType),
      );
      if (sortType != ProxiesSortType.delay) {
        return;
      }
      proxiesAction.updateGroupsDebounce();
    }, duration: const Duration(milliseconds: 5000));
  }

  @override
  void onLog(Log log) {
    _bufferedLogs.add(log);
    if (_bufferedLogs.length > _maxBufferedLogs) {
      _bufferedLogs.removeRange(0, _bufferedLogs.length - _maxBufferedLogs);
    }
    _scheduleFeedFlush();
    if (log.logLevel == LogLevel.error) {
      throttler.call(
        FunctionTag.coreErrorNotifier,
        () => dialogs.showNotifier(log.payload, level: MessageLevel.error),
        duration: const Duration(seconds: 3),
        fire: true,
      );
    }
    super.onLog(log);
  }

  @override
  void onDialerLoop(String proxyName) {
    throttler.call(
      FunctionTag.dialerLoopNotifier,
      () => dialogs.showNotifier(
        currentAppLocalizations.dialerProxyLoopStopped(proxyName),
        level: MessageLevel.error,
      ),
      duration: const Duration(seconds: 3),
      fire: true,
    );
    super.onDialerLoop(proxyName);
  }

  @override
  void onRequest(TrackerInfo trackerInfo) async {
    // Connections history is only useful while the UI is visible; dropping
    // events in the background avoids FixedList rebuild storms on busy links.
    if (ref.read(appVisibleProvider)) {
      _bufferedRequests.add(trackerInfo);
      if (_bufferedRequests.length > _maxBufferedRequests) {
        _bufferedRequests.removeRange(
          0,
          _bufferedRequests.length - _maxBufferedRequests,
        );
      }
      _bufferedRequestCount++;
      _scheduleFeedFlush();
    }
    super.onRequest(trackerInfo);
  }

  @override
  void onDns(DnsQuery dnsQuery) {
    if (ref.read(appVisibleProvider)) {
      _bufferedDns.add(dnsQuery);
      if (_bufferedDns.length > _maxBufferedDns) {
        _bufferedDns.removeRange(0, _bufferedDns.length - _maxBufferedDns);
      }
      _bufferedDnsCount++;
      _scheduleFeedFlush();
    }
    super.onDns(dnsQuery);
  }

  @override
  Future<void> onLoaded(String providerName) async {
    final provider = await _core.getExternalProvider(providerName);
    if (!mounted) {
      return;
    }
    ref.read(providersProvider.notifier).setProvider(provider);
    debouncer.call(FunctionTag.loadedProvider, () async {
      if (!mounted) {
        return;
      }
      ref.read(proxiesActionProvider.notifier).updateGroupsDebounce();
    }, duration: const Duration(milliseconds: 5000));
    super.onLoaded(providerName);
  }

  @override
  Future<void> onCrash(String message) async {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      context.showNotifier(message, level: MessageLevel.error);
    }
    super.onCrash(message);
  }

  @override
  void onGeoUpdate(String geoType, bool updating, bool skipped, String? error) {
    ref
        .read(geoResourceActionProvider.notifier)
        .handleCoreUpdate(geoType, updating, skipped, error);
    super.onGeoUpdate(geoType, updating, skipped, error);
  }

  @override
  void onRouteChanged(RouteSnapshot snapshot) {
    ref.read(routeTrackerProvider.notifier).applySnapshot(snapshot);
    super.onRouteChanged(snapshot);
  }
}
