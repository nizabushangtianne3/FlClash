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
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/route_state.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/banner.dart';

class CoreManager extends ConsumerStatefulWidget {
  final Widget child;

  const CoreManager({super.key, required this.child});

  @override
  ConsumerState<CoreManager> createState() => _CoreContainerState();
}

class _CoreContainerState extends ConsumerState<CoreManager>
    with CoreEventListener {
  CoreController get _core => ref.read(coreHandlerProvider);

  ListQueue<Log> _logs = ListQueue<Log>();
  List<TrackerInfo> _requests = <TrackerInfo>[];
  List<DnsQuery> _dnsQueries = <DnsQuery>[];
  Map<String, RequestTraffic> _traffic = <String, RequestTraffic>{};
  Timer? _feedTimer;

  @override
  bool get wantsRequestEvents => ref.read(appVisibleProvider);

  @override
  bool get wantsDnsEvents => ref.read(appVisibleProvider);

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
    ref.listenManual(globalRulesProvider, (prev, next) {
      if (prev?.value != null && next.hasValue) {
        ref.read(setupActionProvider.notifier).applyIfGlobalRulesUsed();
      }
    });
    ref.listenManual(
      patchClashConfigProvider.select((state) => state.mitm.enable),
      (prev, next) {
        if (prev == false && next) {
          unawaited(ref.read(mitmModulesActionProvider.notifier).autoUpdate());
        }
      },
    );
    ref.listenManual(mitmModulesProvider, (prev, next) {
      if (mitmFeature &&
          prev?.value != null &&
          next.hasValue &&
          ref.read(patchClashConfigProvider).mitm.enable) {
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
    coreEventManager.removeListener(this);
    _feedTimer?.cancel();
    super.dispose();
  }

  @override
  Future<void> onDelay(Delay delay) async {
    super.onDelay(delay);
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    proxiesAction.setDelay(delay);
    debouncer.call(FunctionTag.updateDelay, () async {
      proxiesAction.updateGroupsDebounce();
    }, duration: const Duration(milliseconds: 5000));
  }

  @override
  void onLog(Log log) {
    if (log.logLevel == LogLevel.error) {
      throttler.call(
        FunctionTag.coreErrorNotifier,
        () => dialogs.showBanner(log.payload, level: BannerLevel.error),
        duration: const Duration(seconds: 3),
        fire: true,
      );
    }
    _logs.add(log);
    _scheduleFeedFlush();
    super.onLog(log);
  }

  @override
  void onDialerLoop(String proxyName) {
    throttler.call(
      FunctionTag.dialerLoopNotifier,
      () => dialogs.showBanner(
        currentAppLocalizations.dialerProxyLoopStopped(proxyName),
        level: BannerLevel.error,
      ),
      duration: const Duration(seconds: 3),
      fire: true,
    );
    super.onDialerLoop(proxyName);
  }

  @override
  void onRequest(TrackerInfo trackerInfo) async {
    _requests.add(trackerInfo);
    _scheduleFeedFlush();
    super.onRequest(trackerInfo);
  }

  @override
  void onRequestTraffic(Map<String, RequestTraffic> traffic) {
    _traffic.addAll(traffic);
    _scheduleFeedFlush();
    super.onRequestTraffic(traffic);
  }

  @override
  void onDns(DnsQuery dnsQuery) {
    _dnsQueries.add(dnsQuery);
    _scheduleFeedFlush();
    super.onDns(dnsQuery);
  }

  void _scheduleFeedFlush() {
    _feedTimer ??= Timer(renderThrottleDuration, _flushFeeds);
  }

  void _flushFeeds() {
    _feedTimer = null;
    if (!mounted) {
      return;
    }
    // The buffers are swapped, not copied: what the flush took is its own,
    // and whatever arrives while it runs lands in the fresh buffer.
    final logs = _logs;
    _logs = ListQueue<Log>();
    final requests = _requests;
    _requests = <TrackerInfo>[];
    final dnsQueries = _dnsQueries;
    _dnsQueries = <DnsQuery>[];
    final traffic = _traffic;
    _traffic = <String, RequestTraffic>{};
    if (logs.isNotEmpty) {
      ref.read(logsProvider.notifier).addAll(logs);
    }
    if (requests.isNotEmpty) {
      ref.read(requestsProvider.notifier).addRequests(requests);
      ref
          .read(requestCountProvider.notifier)
          .update((count) => count + requests.length);
    }
    if (traffic.isNotEmpty) {
      ref.read(requestsProvider.notifier).updateTraffic(traffic);
      ref.read(connectionsProvider.notifier).updateTraffic(traffic);
    }
    if (dnsQueries.isNotEmpty) {
      ref.read(dnsQueriesProvider.notifier).addQueries(dnsQueries);
      ref
          .read(dnsQueryCountProvider.notifier)
          .update((count) => count + dnsQueries.length);
    }
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
      dialogs.showBanner(message, level: BannerLevel.error);
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
