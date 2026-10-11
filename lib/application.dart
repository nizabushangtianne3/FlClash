import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/bootstrap.dart';
import 'package:fl_clash/common/system_dns.dart';
import 'package:fl_clash/icons/icons.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/hotkey_manager.dart';
import 'package:fl_clash/manager/manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/focus.dart';
import 'package:fl_clash/widgets/keyboard_inset_hold.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/pages.dart';

Widget buildManagerStack({
  required bool isDesktop,
  required Future<void> Function(List<ConnectivityResult> results)
  onConnectivityChanged,
  required Widget child,
}) {
  final platformApp = isDesktop
      ? WindowHeaderContainer(child: child)
      : VpnManager(child: child);
  final state = AppStateManager(
    child: CoreManager(
      child: ConnectivityManager(
        onConnectivityChanged: onConnectivityChanged,
        child: platformApp,
      ),
    ),
  );
  final platformState = isDesktop
      ? WindowManager(
          child: TrayManager(
            child: HotKeyManager(child: ProxyManager(child: state)),
          ),
        )
      : AndroidManager(child: TileManager(child: state));
  return AppEnvManager(
    child: LocaleManager(
      child: StatusManager(child: ThemeManager(child: platformState)),
    ),
  );
}

class Application extends ConsumerStatefulWidget {
  const Application({super.key});

  @override
  ConsumerState<Application> createState() => ApplicationState();
}

const _actionIconTheme = ActionIconThemeData(
  backButtonIconBuilder: _backButtonIcon,
  closeButtonIconBuilder: _closeButtonIcon,
);

const _autoUpdateRetryFloor = Duration(minutes: 5);
const _autoUpdateRetryCap = Duration(hours: 1);

/// How long to wait before sweeping again while an attempt keeps leaving
/// subscriptions due: one that fails is retried rarely instead of every few
/// minutes, and a wait that short still picks a network back up quickly.
Duration nextAutoUpdateRetryDelay(Duration previous) {
  final doubled = previous * 2;
  return doubled > _autoUpdateRetryCap ? _autoUpdateRetryCap : doubled;
}

/// The nearest due time outside the profiles a failed sweep is backing off.
Duration? nextAutoUpdateSweepDelay({
  required Iterable<Profile> profiles,
  required DateTime now,
  required Map<int, DateTime> retryNotBefore,
}) {
  Duration? next;
  for (final profile in profiles) {
    if (!profile.realAutoUpdate) {
      continue;
    }
    final due = profile.lastUpdateDate == null || profile.isAutoUpdateDue(now);
    final retryTime = retryNotBefore[profile.id];
    if (retryTime != null) {
      if (!due) {
        continue;
      }
      final remaining = retryTime.difference(now);
      if (remaining <= Duration.zero) {
        return Duration.zero;
      }
      if (next == null || remaining < next) {
        next = remaining;
      }
      continue;
    }
    if (due) {
      return Duration.zero;
    }
    final delay = profile.lastUpdateDate!
        .add(profile.autoUpdateDuration)
        .difference(now);
    if (next == null || delay < next) {
      next = delay;
    }
  }
  return next;
}

bool connectivityBecameAvailable(
  Set<ConnectivityResult> previous,
  Set<ConnectivityResult> current,
) {
  bool hasNetwork(Set<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);
  return previous.isNotEmpty && !hasNetwork(previous) && hasNetwork(current);
}

@visibleForTesting
Set<int> changedAutoUpdateProfileIds(
  List<Profile> previous,
  List<Profile> next,
) {
  final previousById = {for (final profile in previous) profile.id: profile};
  final nextById = {for (final profile in next) profile.id: profile};
  return {
    for (final id in previousById.keys.toSet().union(nextById.keys.toSet()))
      if (previousById[id] == null ||
          nextById[id] == null ||
          profileUpdateStateChanged(previousById[id]!, nextById[id]!))
        id,
  };
}

Widget _backButtonIcon(BuildContext context) =>
    GlyphIcon(AppGlyphs.backFor(Theme.of(context).platform));

Widget _closeButtonIcon(BuildContext context) =>
    const GlyphIcon(AppGlyphs.close);

class ApplicationState extends ConsumerState<Application> {
  Timer? _autoUpdateProfilesTaskTimer;
  final _autoUpdateRetryDelays = <int, Duration>{};
  final _autoUpdateRetryNotBefore = <int, DateTime>{};
  Set<ConnectivityResult>? _previousConnectivity;

  final _pageTransitionsTheme = const PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      TargetPlatform.android: commonSharedXPageTransitions,
      TargetPlatform.windows: commonSharedXPageTransitions,
      TargetPlatform.linux: commonSharedXPageTransitions,
      TargetPlatform.macOS: commonSharedXPageTransitions,
    },
  );

  ColorScheme _getAppColorScheme({required Brightness brightness}) {
    return ref.read(genColorSchemeProvider(brightness));
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(profilesProvider, (previous, next) {
      _clearBackoffForChangedProfiles(previous ?? const [], next);
      _scheduleAutoUpdateProfilesTask();
    });
    SystemNavigator.setFrameworkHandlesBack(true);
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      if (globalState.navigatorKey.currentContext != null) {
        await bootstrap.attach();
      } else {
        exit(0);
      }
      _scheduleAutoUpdateProfilesTask();
      _initLink();
      if (!safeModeBuild) {
        unawaited(app?.initShortcuts());
      }
    });
  }

  void _clearBackoffForChangedProfiles(
    List<Profile> previous,
    List<Profile> next,
  ) {
    if (_autoUpdateRetryNotBefore.isEmpty) {
      return;
    }
    final changed = changedAutoUpdateProfileIds(previous, next);
    for (final id in _autoUpdateRetryNotBefore.keys.toList()) {
      if (changed.contains(id)) {
        _autoUpdateRetryDelays.remove(id);
        _autoUpdateRetryNotBefore.remove(id);
      }
    }
  }

  void _initLink() {
    linkManager.initAppLinksListen((url) async {
      unawaited(window?.show());
      final message = currentAppLocalizations.createProfileFromUrlTip(url);
      final parts = message.split(url);
      final res = await dialogs.showMessage(
        title: currentAppLocalizations.addProfile,
        message: TextSpan(
          children: [
            TextSpan(text: parts.first),
            TextSpan(
              text: url,
              style: TextStyle(
                color: context.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: context.colorScheme.primary,
              ),
            ),
            if (parts.length > 1) TextSpan(text: parts.last),
          ],
        ),
      );
      if (res != true) return;
      unawaited(
        ref.read(profilesActionProvider.notifier).addProfileFormURL(url),
      );
    });
  }

  void _scheduleAutoUpdateProfilesTask() {
    _autoUpdateProfilesTaskTimer?.cancel();
    _autoUpdateProfilesTaskTimer = null;
    final delay = nextAutoUpdateSweepDelay(
      profiles: ref.read(profilesProvider),
      now: DateTime.now(),
      retryNotBefore: _autoUpdateRetryNotBefore,
    );
    if (delay == null) {
      return;
    }
    _autoUpdateProfilesTaskTimer = Timer(
      delay,
      () => unawaited(_runAutoUpdateProfilesTask()),
    );
  }

  Future<void> _runAutoUpdateProfilesTask() async {
    final startedAt = DateTime.now();
    final skipProfileIds = {
      for (final entry in _autoUpdateRetryNotBefore.entries)
        if (entry.value.isAfter(startedAt)) entry.key,
    };
    final failed = await ref
        .read(profilesActionProvider.notifier)
        .autoUpdateProfiles(skipProfileIds: skipProfileIds);
    if (!mounted) {
      return;
    }
    final finishedAt = DateTime.now();
    final profiles = ref.read(profilesProvider);
    bool stillDue(int id) {
      final profile = profiles.getProfile(id);
      return profile != null &&
          profile.realAutoUpdate &&
          profile.isAutoUpdateDue(finishedAt);
    }

    final nextDelays = <int, Duration>{};
    final nextRetryNotBefore = <int, DateTime>{};
    for (final entry in _autoUpdateRetryNotBefore.entries) {
      if (skipProfileIds.contains(entry.key) && stillDue(entry.key)) {
        nextDelays[entry.key] =
            _autoUpdateRetryDelays[entry.key] ?? _autoUpdateRetryFloor;
        nextRetryNotBefore[entry.key] = entry.value;
      }
    }
    for (final id in failed) {
      if (!stillDue(id)) {
        continue;
      }
      final previousDelay = _autoUpdateRetryDelays[id];
      final delay = previousDelay == null
          ? _autoUpdateRetryFloor
          : nextAutoUpdateRetryDelay(previousDelay);
      nextDelays[id] = delay;
      nextRetryNotBefore[id] = finishedAt.add(delay);
    }
    _autoUpdateRetryDelays
      ..clear()
      ..addAll(nextDelays);
    _autoUpdateRetryNotBefore
      ..clear()
      ..addAll(nextRetryNotBefore);
    if (_autoUpdateRetryNotBefore.isEmpty) {
      _scheduleAutoUpdateProfilesTask();
      return;
    }
    _scheduleAutoUpdateProfilesTask();
  }

  Future<void> _handleConnectivityChanged(
    List<ConnectivityResult> results,
  ) async {
    final currentConnectivity = results.toSet();
    final previousConnectivity = _previousConnectivity;
    if (previousConnectivity != null &&
        previousConnectivity.length == currentConnectivity.length &&
        previousConnectivity.containsAll(currentConnectivity)) {
      return;
    }
    _previousConnectivity = currentConnectivity;
    commonPrint.log('connectivityChanged ${results.toString()}');
    unawaited(systemDnsCoordinator?.resync() ?? Future.value());
    unawaited(ref.read(systemActionProvider.notifier).updateLocalIp());
    if (connectivityBecameAvailable(
      previousConnectivity ?? const {},
      currentConnectivity,
    )) {
      _autoUpdateRetryDelays.clear();
      _autoUpdateRetryNotBefore.clear();
      _scheduleAutoUpdateProfilesTask();
    }
    final hasVpn = currentConnectivity.contains(ConnectivityResult.vpn);
    final hadVpn = previousConnectivity?.contains(ConnectivityResult.vpn);
    if (hadVpn != null && hadVpn != hasVpn) {
      ref.read(routeTrackerProvider.notifier).bumpHostEpoch();
    }
  }

  @override
  Widget build(context) {
    return Consumer(
      builder: (_, ref, child) {
        final locale = ref.watch(
          appSettingProvider.select((state) => state.locale),
        );
        final themeProps = ref.watch(themeSettingProvider);
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: globalState.navigatorKey,
          onNavigationNotification: (_) => true,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          builder: (context, child) {
            return buildManagerStack(
              isDesktop: system.isDesktop,
              onConnectivityChanged: _handleConnectivityChanged,
              child: RemoteFocusAdapter(enabled: system.isTV, child: child!),
            );
          },
          scrollBehavior: const BaseScrollBehavior(),
          title: appName,
          locale: getLocaleForString(locale),
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          themeMode: themeProps.themeMode,
          theme: ThemeData(
            useMaterial3: true,
            pageTransitionsTheme: _pageTransitionsTheme,
            actionIconTheme: _actionIconTheme,
            colorScheme: _getAppColorScheme(brightness: Brightness.light),
          ).withAppShapes,
          darkTheme: ThemeData(
            useMaterial3: true,
            pageTransitionsTheme: _pageTransitionsTheme,
            actionIconTheme: _actionIconTheme,
            colorScheme: _getAppColorScheme(brightness: Brightness.dark),
          ).withAppShapes,
          home: KeyboardInsetHold(child: child!),
        );
      },
      child: const HomePage(),
    );
  }

  @override
  void dispose() {
    linkManager.destroy();
    _autoUpdateProfilesTaskTimer?.cancel();
    super.dispose();
  }
}
