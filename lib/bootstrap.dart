import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:fl_clash/common/boot_guard.dart';
import 'package:fl_clash/common/boot_record.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/launch.dart';
import 'package:fl_clash/common/migration.dart';
import 'package:fl_clash/common/tray.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/disclaimer.dart';
import 'package:fl_clash/views/navigation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_color_utilities/palettes/tonal_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';

class Bootstrap {
  static Bootstrap? _instance;

  Bootstrap._internal();

  factory Bootstrap() {
    _instance ??= Bootstrap._internal();
    return _instance!;
  }

  BootDecision _bootDecision = const BootDecision();

  Future<ProviderContainer> init(int version, {Size? viewSize}) async {
    globalState.appEnv = const String.fromEnvironment(
      'APP_ENV',
      defaultValue: 'pre',
    );
    windowPort = window;
    trayPort = appTray;
    navigationPort = navigation;
    final packageInfoFuture = PackageInfo.fromPlatform();
    final config = await migration.run();
    // Only an adaptive theme needs the system palette.
    final dynamicColor = config.themeProps.primaryColor == null
        ? await _initDynamicColor()
        : const (
            lightSeed: null,
            darkSeed: null,
            accentColor: Color(defaultPrimaryColor),
          );
    return _initData(
      version,
      config,
      dynamicColor,
      packageInfoFuture,
      viewSize,
    );
  }

  Future<DynamicColorSeeds> _initDynamicColor() async {
    TonalPalette? primaryPalette;
    Color? accentColor;
    final primaryPaletteFuture = _getSystemPrimaryPalette();
    final accentColorFuture = DynamicColorPlugin.getAccentColor();
    try {
      primaryPalette = await primaryPaletteFuture;
    } catch (error) {
      commonPrint.log(
        'Failed to get core palette: $error',
        logLevel: LogLevel.warning,
      );
    }
    try {
      accentColor = await accentColorFuture;
    } catch (error) {
      commonPrint.log(
        'Failed to get accent color: $error',
        logLevel: LogLevel.warning,
      );
    }
    return (
      lightSeed: primaryPalette != null ? Color(primaryPalette.get(40)) : null,
      darkSeed: primaryPalette != null ? Color(primaryPalette.get(80)) : null,
      accentColor: accentColor ?? const Color(defaultPrimaryColor),
    );
  }

  /// Runs before migration and the database: a copy started from another
  /// install path gets past the platform's single-instance hand-off.
  Future<void> _claimDataDirectory() async {
    if (!system.isDesktop || await singleInstanceLock.acquire()) {
      return;
    }
    commonPrint.log('another instance owns the data directory, exiting');
    exit(0);
  }

  Future<TonalPalette?> _getSystemPrimaryPalette() async {
    final raw = await DynamicColorPlugin.channel.invokeMethod<List<dynamic>>(
      DynamicColorPlugin.methodName,
    );
    if (raw == null || raw.length < TonalPalette.commonSize) {
      return null;
    }
    return TonalPalette.fromList(
      raw.sublist(0, TonalPalette.commonSize).cast<int>(),
    );
  }

  Future<ProviderContainer> _initData(
    int version,
    Config initialConfig,
    DynamicColorSeeds dynamicColor,
    Future<PackageInfo> packageInfoFuture,
    Size? viewSize,
  ) async {
    await _claimDataDirectory();
    globalState.packageInfo = await packageInfoFuture;
    var config = initialConfig;
    _bootDecision = await bootGuard.evaluate(
      profileId: config.currentProfileId,
    );
    if (_bootDecision.recovery == BootRecovery.clearProfile) {
      config = config.copyWith(currentProfileId: null);
      await preferences.saveConfig(config);
    }
    final patchClashConfig = config.patchClashConfig.ensureControllerSecret();
    if (patchClashConfig != config.patchClashConfig) {
      config = config.copyWith(patchClashConfig: patchClashConfig);
      await preferences.saveConfig(config);
    }
    final appState = AppState(
      brightness: WidgetsBinding.instance.platformDispatcher.platformBrightness,
      version: version,
      viewSize: viewSize ?? Size.zero,
      requests: FixedList(maxRequestsLength, keyOf: (request) => request.id),
      logs: FixedList(maxLogsLength),
      traffics: FixedList(trafficSampleLength),
      totalTraffic: const Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    final appStateOverrides = buildAppStateOverrides(appState);
    final configOverrides = buildConfigOverrides(config);
    final container = ProviderContainer(
      overrides: [...appStateOverrides, ...configOverrides],
    );
    globalState.container = container;
    container
        .read(dynamicColorProvider.notifier)
        .seed(
          lightSeed: dynamicColor.lightSeed,
          darkSeed: dynamicColor.darkSeed,
          accentColor: dynamicColor.accentColor,
        );
    final locale =
        getLocaleForString(config.appSettingProps.locale) ??
        WidgetsBinding.instance.platformDispatcher.locale;
    final profilesFuture = database.profilesDao.query().get();
    final localizationFuture = AppLocalizations.load(locale);
    final windowFuture =
        window?.init(version, config.windowProps) ?? Future<void>.value();
    final (profiles, _, _) = await (
      profilesFuture,
      localizationFuture,
      windowFuture,
    ).wait;
    container.read(profilesProvider.notifier).setInitial(profiles);
    if (system.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    return container;
  }

  Future<void> attach() async {
    if (globalState.isAttach == true) {
      return;
    }
    await _initApp();
    globalState.isAttach = true;
  }

  ProviderContainer get _container => globalState.container;

  Future<void> _initApp() async {
    unawaited(_container.read(systemActionProvider.notifier).updateTray());
    unawaited(
      _container.read(profilesActionProvider.notifier).autoUpdateProfiles(),
    );
    unawaited(
      autoLaunch?.updateStatus(_container.read(appSettingProvider).autoLaunch),
    );
    if (!_container.read(appSettingProvider).silentLaunch) {
      unawaited(window?.show());
    } else {
      unawaited(window?.hide());
    }
    await _handleFailedPreference();
    final isFirstLaunch =
        _container.read(
          appSettingProvider.select((state) => state.acceptedDisclaimerVersion),
        ) ==
        0;
    if (!isFirstLaunch) {
      unawaited(
        _container.read(commonActionProvider.notifier).autoCheckUpdate(),
      );
    }
    if (!await _handlerDisclaimer(isFirstLaunch)) {
      return;
    }
    await _showCrashRecoveryTip();
    await _container.read(coreActionProvider.notifier).startCore();
    if (!_bootDecision.isDegraded) {
      await _container.read(setupActionProvider.notifier).initStatus();
    }
    _container.read(initProvider.notifier).value = true;
    unawaited(_container.read(resourcesActionProvider.notifier).autoUpdate());
    await bootGuard.markRunning();
    if (!isFirstLaunch) {
      unawaited(
        _container.read(locationPermissionsProvider.notifier).refresh(),
      );
    }
  }

  Future<void> _showCrashRecoveryTip() async {
    switch (_bootDecision.recovery) {
      case BootRecovery.none:
        return;
      case BootRecovery.skipAutoSetup:
        await dialogs.showAlert(
          title: currentAppLocalizations.launchInterrupted,
          dismissible: false,
          message: TextSpan(text: currentAppLocalizations.launchInterruptedTip),
        );
      case BootRecovery.clearProfile:
        await dialogs.showAlert(
          title: currentAppLocalizations.crashDetected,
          dismissible: false,
          message: TextSpan(
            text: currentAppLocalizations.crashDetectedTip(_failedProfileLabel),
          ),
        );
    }
  }

  String get _failedProfileLabel {
    final profileId = _bootDecision.failedProfileId;
    if (profileId == null) {
      return '';
    }
    final profile = _container.read(profilesProvider).getProfile(profileId);
    return profile?.label.takeFirstValid(['$profileId']) ?? '$profileId';
  }

  Future<void> _handleFailedPreference() async {
    if (await preferences.isInit) return;
    final res = await dialogs.showMessage(
      title: currentAppLocalizations.tip,
      message: TextSpan(text: currentAppLocalizations.cacheCorrupt),
    );
    if (res == true) {
      final file = File(await appPath.sharedPreferencesPath);
      await file.safeDelete();
    }
    // Saving here would rewrite the preferences file the user just chose to delete.
    await _container.read(systemActionProvider.notifier).handleExit(false);
  }

  /// Unattended desktop installs, such as a container nobody watches, accept
  /// up front: the core only starts after the disclaimer is accepted.
  bool get _isDisclaimerAcceptedByEnvironment =>
      system.isDesktop &&
      Platform.environment['FLCLASH_ACCEPT_DISCLAIMER'] == '1';

  /// Android's exit only finishes the activity, so Dart keeps running after
  /// [SystemAction.handleExit] returns and must not go on to start the app.
  Future<bool> _handlerDisclaimer(bool isFirstLaunch) async {
    final acceptedVersion = _container.read(
      appSettingProvider.select((state) => state.acceptedDisclaimerVersion),
    );
    final accepted = acceptedVersion >= disclaimerVersion;
    if (accepted || (!isFirstLaunch && _isDisclaimerAcceptedByEnvironment)) {
      _container
          .read(appSettingProvider.notifier)
          .update(
            (state) =>
                state.copyWith(acceptedDisclaimerVersion: disclaimerVersion),
          );
      return true;
    }
    final isDisclaimerAccepted = await requestDisclaimerConsent();
    if (!isDisclaimerAccepted) {
      await _container.read(systemActionProvider.notifier).handleExit();
      return false;
    }
    _container
        .read(appSettingProvider.notifier)
        .update(
          (state) =>
              state.copyWith(acceptedDisclaimerVersion: disclaimerVersion),
        );
    return true;
  }
}

final bootstrap = Bootstrap();
