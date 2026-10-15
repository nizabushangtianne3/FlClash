import 'dart:async';
import 'dart:collection';

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

  late final CoreController _coreController;
  bool _isVisible = true;

  Timer? _feedFlushTimer;
  final ListQueue<Log> _bufferedLogs = ListQueue();
  final ListQueue<TrackerInfo> _bufferedRequests = ListQueue();
  final ListQueue<DnsQuery> _bufferedDns = ListQueue();
  int _bufferedRequestCount = 0;
  int _bufferedDnsCount = 0;
  late final Logs _logsNotifier;
  late final Requests _requestsNotifier;
  late final DnsQueries _dnsNotifier;
  late final RequestCount _requestCountNotifier;
  late final DnsQueryCount _dnsCountNotifier;

  @override
  bool get wantsRequestEvents => mounted && _isVisible;

  @override
  bool get wantsDnsEvents => mounted && _isVisible;

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
    _coreController = _core;
    _logsNotifier = ref.read(logsProvider.notifier);
    _requestsNotifier = ref.read(requestsProvider.notifier);
    _dnsNotifier = ref.read(dnsQueriesProvider.notifier);
    _requestCountNotifier = ref.read(requestCountProvider.notifier);
    _dnsCountNotifier = ref.read(dnsQueryCountProvider.notifier);
    _isVisible = ref.read(appVisibleProvider);
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
        _syncMessageStreams();
      }
    });
    ref.listenManual(appVisibleProvider, (_, _) => _syncMessageStreams());
  }

  void _syncLogStream() {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    if (_isVisible && ref.read(appSettingProvider).openLogs) {
      _core.startLog();
    } else {
      _core.stopLog();
    }
  }

  void _syncMessageStreams() {
    _isVisible = ref.read(appVisibleProvider);
    _syncLogStream();
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    if (_isVisible) {
      _core.startRequestMessages();
      _core.startDnsMessages();
    } else {
      _core.stopRequestMessages();
      _core.stopDnsMessages();
      // A flush queued just before hiding would still publish one batch.
      _feedFlushTimer?.cancel();
      _feedFlushTimer = null;
      _bufferedRequests.clear();
      _bufferedDns.clear();
      _bufferedRequestCount = 0;
      _bufferedDnsCount = 0;
    }
  }

  @override
  void dispose() {
    _feedFlushTimer?.cancel();
    _flushFeeds();
    _coreController.stopRequestMessages();
    _coreController.stopDnsMessages();
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
      _logsNotifier.addAll(_bufferedLogs);
      _bufferedLogs.clear();
    }
    if (_bufferedRequests.isNotEmpty) {
      _requestsNotifier.addRequests(_bufferedRequests);
      _bufferedRequests.clear();
    }
    if (_bufferedDns.isNotEmpty) {
      _dnsNotifier.addQueries(_bufferedDns);
      _bufferedDns.clear();
    }
    if (_bufferedRequestCount != 0) {
      final delta = _bufferedRequestCount;
      _bufferedRequestCount = 0;
      _requestCountNotifier.update((count) => count + delta);
    }
    if (_bufferedDnsCount != 0) {
      final delta = _bufferedDnsCount;
      _bufferedDnsCount = 0;
      _dnsCountNotifier.update((count) => count + delta);
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
    // Delay tests only change sort order — re-sort the cached groups without
    // a full Core getProxies (critical for large subscriptions).
    proxiesAction.resortGroupsByDelayDebounce(
      const Duration(milliseconds: 5000),
    );
  }

  @override
  void onLog(Log log) {
    _appendBounded(_bufferedLogs, log, _maxBufferedLogs);
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
    if (!mounted) {
      return;
    }
    // Connections history is only useful while the UI is visible; dropping
    // events in the background avoids FixedList rebuild storms on busy links.
    if (_isVisible) {
      _appendBounded(_bufferedRequests, trackerInfo, _maxBufferedRequests);
      _bufferedRequestCount++;
      _scheduleFeedFlush();
    }
    super.onRequest(trackerInfo);
  }

  @override
  void onDns(DnsQuery dnsQuery) {
    if (!mounted) {
      return;
    }
    if (_isVisible) {
      _appendBounded(_bufferedDns, dnsQuery, _maxBufferedDns);
      _bufferedDnsCount++;
      _scheduleFeedFlush();
    }
    super.onDns(dnsQuery);
  }

  void _appendBounded<T>(ListQueue<T> queue, T value, int maxLength) {
    queue.addLast(value);
    if (queue.length > maxLength) {
      queue.removeFirst();
    }
  }

  @override
  Future<void> onLoaded(String providerName) async {
    if (!mounted) {
      return;
    }
    // Provider load advances the Core generation immediately; drop the host
    // cache now so a concurrent getProxies cannot serve the previous tree.
    _core.invalidateProxiesCache();
    // A provider may replace a node with another server that keeps its name.
    // The old name-keyed delay must not speak for the replacement node.
    ref.read(delayDataSourceProvider.notifier).value = {};
    final providerFuture = _core.getExternalProvider(providerName);
    debouncer.call(FunctionTag.loadedProvider, () async {
      if (!mounted) {
        return;
      }
      ref.read(proxiesActionProvider.notifier).updateGroupsDebounce();
    }, duration: const Duration(seconds: 1));
    final provider = await providerFuture;
    if (!mounted) {
      return;
    }
    ref.read(providersProvider.notifier).setProvider(provider);
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
    if (!mounted) {
      return;
    }
    final route = ref.read(routeTrackerProvider);
    final applyPicks =
        !route.synced || route.picksVersion != snapshot.picksVersion;
    ref.read(routeTrackerProvider.notifier).applySnapshot(snapshot);
    if (applyPicks) {
      ref
          .read(proxiesActionProvider.notifier)
          .applyRoutePicks(
            snapshot.picks,
            closeConnections:
                route.synced && route.coreEpoch == snapshot.coreEpoch,
          );
    }
    super.onRouteChanged(snapshot);
  }
}
