import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:tray/tray.dart';

import 'app_localizations.dart';
import 'l10n_labels.dart';
import 'app_ports.dart';
import 'constant.dart';
import 'keyboard.dart';
import 'provider_reader.dart';
import 'system.dart';
import 'window.dart';

class AppTray implements TrayPort {
  static AppTray? _instance;

  final bool isMacOS;
  final bool isWindows;

  bool _isShutDown = false;

  /// Last title actually pushed to NSStatusItem. Used to skip no-op setTitle.
  String? _lastTitle;

  /// Fingerprint of the last full tray (icon + menu) rebuild.
  String? _lastTrayFingerprint;

  AppTray._internal({required this.isMacOS, required this.isWindows});

  factory AppTray() {
    _instance ??= AppTray._internal(
      isMacOS: system.isMacOS,
      isWindows: system.isWindows,
    );
    return _instance!;
  }

  @visibleForTesting
  factory AppTray.forPlatform({
    required bool isMacOS,
    required bool isWindows,
  }) {
    return AppTray._internal(isMacOS: isMacOS, isWindows: isWindows);
  }

  String get _trayIconSuffix {
    return isWindows ? 'ico' : 'png';
  }

  bool _isTemplate(bool monochrome) => isMacOS && monochrome;

  String _trayIconDir(bool monochrome) {
    if (isWindows) {
      return 'assets/images/tray/windows';
    }
    return _isTemplate(monochrome)
        ? 'assets/images/tray/macos'
        : 'assets/images/tray/unix';
  }

  String getTrayIcon({
    required bool isStart,
    required bool tunEnable,
    required bool safeMode,
    bool monochrome = true,
  }) {
    final status = switch ((
      safeMode,
      _isTemplate(monochrome) || !isStart,
      tunEnable,
    )) {
      (true, _, _) => 4,
      (false, true, _) => 1,
      (false, false, false) => 2,
      (false, false, true) => 3,
    };
    return '${_trayIconDir(monochrome)}/status_$status.$_trayIconSuffix';
  }

  /// Stable key for "does the tray shell need a native rebuild?"
  String _trayFingerprint(
    TrayState trayState,
    Map<String, Map<String, int>> delays,
  ) {
    final selected = trayState.selectedMap.entries
        .map((e) => '${e.key}=${e.value}:${delays[e.key]?[e.value] ?? ''}')
        .join(',');
    final groupSig = trayState.groups
        .map((g) => '${g.name}:${g.all.map((p) => p.name).join(',')}')
        .join(';');
    final hotKeySig = trayState.hotKeys.entries
        .map(
          (entry) =>
              '${entry.key.name}:${entry.value.key}:'
              '${entry.value.modifiers.map((item) => item.name).join(',')}',
        )
        .join(',');
    final delaySig = delays.entries
        .map(
          (entry) =>
              '${entry.key}:${entry.value.entries.map((delay) => '${delay.key}=${delay.value}').join(',')}',
        )
        .join(';');
    return [
      trayState.isStart,
      trayState.tunEnable,
      trayState.safeMode,
      trayState.systemProxy,
      trayState.autoLaunch,
      trayState.mode,
      trayState.showTrayTitle,
      selected,
      groupSig,
      delaySig,
      hotKeySig,
    ].join('|');
  }

  @override
  Future<void> shutdown() async {
    _isShutDown = true;
    _lastTitle = null;
    _lastTrayFingerprint = null;
    // Removing a status item makes macOS forget where the user dragged it in
    // the menu bar; one that goes away with the process keeps its place.
    if (isMacOS) {
      return;
    }
    await Tray.instance.hide();
  }

  @override
  Future<void> update({
    required TrayState trayState,
    required Traffic traffic,
    required ProviderReader read,
  }) async {
    if (_isShutDown) {
      return;
    }
    final delays = isMacOS
        ? read(trayDelaysProvider)
        : const <String, Map<String, int>>{};
    final monochrome = trayState.monochromeTrayIcon;
    final fingerprint = _trayFingerprint(trayState, delays);
    final needRebuild = fingerprint != _lastTrayFingerprint;

    if (needRebuild) {
      _lastTrayFingerprint = fingerprint;
      await Tray.instance.show(
        TraySpec(
          icon: TrayIcon.asset(
            getTrayIcon(
              isStart: trayState.isStart && !trayState.suspended,
              tunEnable: trayState.tunEnable,
              safeMode: trayState.safeMode,
              monochrome: monochrome,
            ),
            isTemplate: _isTemplate(monochrome),
            size: isMacOS ? 18 : 16,
          ),
          toolTip: trayState.safeMode
              ? currentAppLocalizations.safeModeAppTitle(appName)
              : appName,
          menu: _buildMenu(trayState: trayState, read: read),
        ),
      );
    }

    await updateTitle(showTrayTitle: trayState.showTrayTitle, traffic: traffic);
  }

  /// Push title only when the visible string actually changes.
  ///
  /// On macOS, every [Tray.instance.setTitle] forces an NSStatusItem /
  /// Control Center replicant redraw. Calling it every second with an empty
  /// string (when speed stats are off) is enough to pin ~30–60% CPU.
  Future<void> updateTitle({
    required bool showTrayTitle,
    required Traffic traffic,
  }) async {
    if (_isShutDown || !isMacOS) {
      return;
    }

    final String next;
    if (!showTrayTitle) {
      // Clear once, then stop touching the status item.
      if (_lastTitle == null || _lastTitle!.isEmpty) {
        return;
      }
      next = '';
    } else {
      next = traffic.trayTitle;
      if (next == _lastTitle) {
        return;
      }
    }

    _lastTitle = next;
    await Tray.instance.setTitle(next);
  }

  List<TrayMenuItem> _buildMenu({
    required TrayState trayState,
    required ProviderReader read,
  }) {
    final commonAction = read(commonActionProvider.notifier);
    final systemAction = read(systemActionProvider.notifier);
    final setupAction = read(setupActionProvider.notifier);
    final appLocalizations = currentAppLocalizations;
    String? shortcut(HotAction action) => _shortcut(trayState, action);
    final showItem = TrayMenuAction(
      label: appLocalizations.show,
      detail: shortcut(HotAction.view),
      onSelected: () {
        window?.show();
      },
    );
    final exitItem = TrayMenuAction(
      label: appLocalizations.exit,
      detail: shortcut(HotAction.exit),
      onSelected: () {
        systemAction.handleExit();
      },
    );

    return [
      showItem,
      TrayMenuCheckbox(
        label: trayState.isStart
            ? appLocalizations.stop
            : appLocalizations.start,
        checked: false,
        detail: shortcut(HotAction.start),
        onSelected: commonAction.toggleRunning,
      ),
      if (isMacOS) ...[
        TrayMenuCheckbox(
          label: appLocalizations.speedStatistics,
          checked: trayState.showTrayTitle,
          onSelected: commonAction.updateSpeedStatistics,
        ),
        TrayMenuCheckbox(
          label: appLocalizations.monochromeIcon,
          checked: trayState.monochromeTrayIcon,
          onSelected: commonAction.updateMonochromeTrayIcon,
        ),
      ],
      const TrayMenuSeparator(),
      for (final mode in Mode.values)
        TrayMenuCheckbox(
          label: mode.label,
          checked: mode == trayState.mode,
          detail: shortcut(switch (mode) {
            Mode.rule => HotAction.ruleMode,
            Mode.global => HotAction.globalMode,
            Mode.direct => HotAction.directMode,
          }),
          onSelected: () {
            setupAction.changeMode(mode);
          },
        ),
      const TrayMenuSeparator(),
      if (isMacOS) ..._buildGroupMenu(trayState: trayState, read: read),
      if (trayState.isStart) ...[
        TrayMenuCheckbox(
          label: appLocalizations.tun,
          checked: trayState.tunEnable,
          detail: shortcut(HotAction.tun),
          onSelected: systemAction.updateTun,
        ),
        TrayMenuCheckbox(
          label: appLocalizations.systemProxy,
          checked: trayState.systemProxy,
          detail: shortcut(HotAction.proxy),
          onSelected: systemAction.updateSystemProxy,
        ),
        const TrayMenuSeparator(),
      ],
      TrayMenuCheckbox(
        label: appLocalizations.autoLaunch,
        checked: trayState.autoLaunch,
        onSelected: systemAction.updateAutoLaunch,
      ),
      TrayMenuAction(
        label: appLocalizations.copyEnvVar,
        detail: shortcut(HotAction.copyEnv),
        onSelected: systemAction.copyProxyEnv,
      ),
      const TrayMenuSeparator(),
      exitItem,
    ];
  }

  String? _shortcut(TrayState trayState, HotAction action) {
    final hotKey = trayState.hotKeys[action];
    final key = hotKey?.key;
    if (hotKey == null || key == null) {
      return null;
    }
    return ShortcutLabels(
      isMacOS: isMacOS,
      isWindows: isWindows,
    ).text(hotKey.modifiers, key);
  }

  String? _delayText(int? delay) {
    if (delay == null) {
      return null;
    }
    return delay > 0
        ? '$delay'
        : delayFailureText(delay, currentAppLocalizations);
  }

  List<TrayMenuItem> _buildGroupMenu({
    required TrayState trayState,
    required ProviderReader read,
  }) {
    if (trayState.groups.isEmpty) {
      return const [];
    }
    final delays = read(trayDelaysProvider);
    final proxiesAction = read(proxiesActionProvider.notifier);
    return [
      for (final group in trayState.groups)
        _buildGroupSubmenu(
          group,
          selectedName: read(selectedProxyNameProvider(group.name)),
          delays: delays[group.name] ?? const {},
          onSelected: (proxyName) {
            proxiesAction.changeProxy(
              groupName: group.name,
              proxyName: proxyName,
            );
          },
        ),
      TrayMenuAction(
        label: HotAction.delayTest.label,
        detail: _shortcut(trayState, HotAction.delayTest),
        onSelected: () {
          proxiesAction.delayTestGroups(trayState.groups);
        },
      ),
      const TrayMenuSeparator(),
    ];
  }

  TrayMenuSubmenu _buildGroupSubmenu(
    Group group, {
    required String? selectedName,
    required Map<String, int> delays,
    required void Function(String proxyName) onSelected,
  }) {
    final all = group.all;
    // Keep the selected proxy, then fill up to the cap with the rest.
    final List<Proxy> visible;
    if (all.length <= maxTrayProxiesPerGroup) {
      visible = all;
    } else {
      final selected = all.where((p) => p.name == selectedName);
      final others = all.where((p) => p.name != selectedName);
      visible = [
        ...selected,
        ...others.take(maxTrayProxiesPerGroup - selected.length),
      ];
    }

    final items = <TrayMenuItem>[
      for (final proxy in visible)
        TrayMenuCheckbox(
          label: proxy.name,
          checked: selectedName == proxy.name,
          detail: _delayText(delays[proxy.name]),
          onSelected: () {
            onSelected(proxy.name);
          },
        ),
    ];

    if (all.length > maxTrayProxiesPerGroup) {
      items.add(
        TrayMenuAction(
          label: '… ${all.length - visible.length} more',
          onSelected: () {
            window?.show();
          },
        ),
      );
    }

    return TrayMenuSubmenu(
      label: group.name,
      detail: _delayText(delays[selectedName]),
      items: items,
    );
  }
}

final appTray = system.isDesktop ? AppTray() : null;
