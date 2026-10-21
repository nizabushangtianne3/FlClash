import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/config.g.dart';

@riverpod
class AppSetting extends _$AppSetting with AutoDisposeNotifierMixin {
  @override
  AppSettingProps build() {
    return const AppSettingProps();
  }
}

@Riverpod(keepAlive: true)
class WindowSetting extends _$WindowSetting with AutoDisposeNotifierMixin {
  @override
  WindowProps build() {
    return const WindowProps();
  }
}

@riverpod
class VpnSetting extends _$VpnSetting with AutoDisposeNotifierMixin {
  @override
  VpnProps build() {
    return const VpnProps();
  }
}

@riverpod
class NetworkSetting extends _$NetworkSetting with AutoDisposeNotifierMixin {
  @override
  NetworkProps build() {
    return const NetworkProps();
  }
}

@riverpod
class ThemeSetting extends _$ThemeSetting with AutoDisposeNotifierMixin {
  @override
  ThemeProps build() {
    return const ThemeProps();
  }
}

@riverpod
class CurrentProfileId extends _$CurrentProfileId
    with AutoDisposeNotifierMixin {
  @override
  int? build() {
    return null;
  }
}

@riverpod
class DavSetting extends _$DavSetting with AutoDisposeNotifierMixin {
  @override
  DAVProps? build() {
    return null;
  }
}

@riverpod
class HotKeyActions extends _$HotKeyActions with AutoDisposeNotifierMixin {
  @override
  List<HotKeyAction> build() {
    return [];
  }
}

@riverpod
class ProxiesStyleSetting extends _$ProxiesStyleSetting
    with AutoDisposeNotifierMixin {
  @override
  ProxiesStyleProps build() {
    return const ProxiesStyleProps();
  }
}

@Riverpod(name: 'patchClashConfigProvider')
class _PatchClashConfig extends _$PatchClashConfig
    with AutoDisposeNotifierMixin {
  @override
  PatchClashConfig build() {
    return const PatchClashConfig();
  }
}

/// Where the app's own requests go, and which hosts skip it. Kept alive and
/// precompiled because every request reads it, outside the widget tree.
@Riverpod(keepAlive: true)
LocalProxyRoute localProxyRoute(Ref ref) {
  final mixedPort = ref.watch(
    patchClashConfigProvider.select((state) => state.mixedPort),
  );
  final networkProps = ref.watch(
    networkSettingProvider.select(
      (state) => (
        authentication: state.authentication,
        bypassDomain: state.bypassDomain,
        bypassPrivateRoute: state.bypassPrivateRoute,
      ),
    ),
  );
  final credentials = networkProps.authentication.credentials;
  final userInfo = credentials.isNotEmpty ? '${credentials.first}@' : '';
  return LocalProxyRoute(
    target: 'PROXY ${userInfo}localhost:$mixedPort',
    bypass: [
      for (final domain in networkProps.bypassDomain) _bypassPattern(domain),
    ],
    bypassPrivateRoute: networkProps.bypassPrivateRoute,
  );
}

class LocalProxyRoute {
  const LocalProxyRoute({
    required this.target,
    required this.bypass,
    required this.bypassPrivateRoute,
  });

  final String target;
  final List<RegExp> bypass;
  final bool bypassPrivateRoute;

  bool bypasses(Uri url) {
    final host = url.host;
    if (bypass.any((pattern) => pattern.hasMatch(host))) {
      return true;
    }
    if (!bypassPrivateRoute) {
      return false;
    }
    final address = InternetAddress.tryParse(host);
    if (address == null) {
      return false;
    }
    final raw = address.rawAddress;
    return _privateRoutePrefixes.any((prefix) => _containsPrefix(prefix, raw));
  }
}

// The bypass list the system proxy applies, so this override has to agree with
// it: `*` and `?` are wildcards, and a bare name also covers its subdomains.
RegExp _bypassPattern(String domain) {
  final wildcard = domain.contains('*') || domain.contains('?');
  final expression = domain.splitMapJoin(
    RegExp(r'[*?]'),
    onMatch: (match) => match.group(0) == '*' ? '.*' : '.',
    onNonMatch: RegExp.escape,
  );
  return RegExp(
    wildcard
        ? '^$expression\$'
        : r'^(.*\.)?'
              '$expression'
              r'$',
    caseSensitive: false,
  );
}

// Parsed once; the ranges the Core excludes from its TUN routes when asked.
final _privateRoutePrefixes = [
  for (final cidr in privateRouteAddress) _parseCidr(cidr),
];

({List<int> base, int bits}) _parseCidr(String cidr) {
  final slash = cidr.lastIndexOf('/');
  return (
    base: InternetAddress(cidr.substring(0, slash)).rawAddress,
    bits: int.parse(cidr.substring(slash + 1)),
  );
}

bool _containsPrefix(({List<int> base, int bits}) prefix, List<int> raw) {
  final (:base, :bits) = prefix;
  if (base.length != raw.length) {
    return false;
  }
  for (var index = 0; index < bits ~/ 8; index++) {
    if (raw[index] != base[index]) {
      return false;
    }
  }
  final rest = bits % 8;
  return rest == 0 ||
      raw[bits ~/ 8] >> (8 - rest) == base[bits ~/ 8] >> (8 - rest);
}

@riverpod
class ExcludeSSIDs extends _$ExcludeSSIDs with AutoDisposeNotifierMixin {
  @override
  List<String> build() {
    return [];
  }
}

@Riverpod(name: 'configProvider')
Config _config(Ref ref) {
  final appSettingProps = ref.watch(appSettingProvider);
  final windowProps = ref.watch(windowSettingProvider);
  final vpnProps = ref.watch(vpnSettingProvider);
  final networkProps = ref.watch(networkSettingProvider);
  final themeProps = ref.watch(themeSettingProvider);
  final currentProfileId = ref.watch(currentProfileIdProvider);
  final davProps = ref.watch(davSettingProvider);
  final hotKeyActions = ref.watch(hotKeyActionsProvider);
  final proxiesStyleProps = ref.watch(proxiesStyleSettingProvider);
  final patchClashConfig = ref.watch(patchClashConfigProvider);
  final excludeSSIDs = ref.watch(excludeSSIDsProvider);
  return Config(
    appSettingProps: appSettingProps,
    windowProps: windowProps,
    vpnProps: vpnProps,
    networkProps: networkProps,
    themeProps: themeProps,
    currentProfileId: currentProfileId,
    davProps: davProps,
    hotKeyActions: hotKeyActions,
    proxiesStyleProps: proxiesStyleProps,
    patchClashConfig: patchClashConfig,
    excludeSSIDs: excludeSSIDs,
  );
}

void writeConfig(Ref ref, Config config) {
  ref.read(appSettingProvider.notifier).value = config.appSettingProps;
  ref.read(windowSettingProvider.notifier).value = config.windowProps;
  ref.read(vpnSettingProvider.notifier).value = config.vpnProps;
  ref.read(networkSettingProvider.notifier).value = config.networkProps;
  ref.read(themeSettingProvider.notifier).value = config.themeProps;
  ref.read(currentProfileIdProvider.notifier).value = config.currentProfileId;
  ref.read(davSettingProvider.notifier).value = config.davProps;
  ref.read(hotKeyActionsProvider.notifier).value = config.hotKeyActions;
  ref.read(proxiesStyleSettingProvider.notifier).value =
      config.proxiesStyleProps;
  ref.read(patchClashConfigProvider.notifier).value = config.patchClashConfig
      .ensureControllerSecret();
  ref.read(excludeSSIDsProvider.notifier).value = config.excludeSSIDs;
}

List<Override> buildConfigOverrides(Config config) {
  return [
    appSettingProvider.overrideWithBuild((_, _) => config.appSettingProps),
    windowSettingProvider.overrideWithBuild((_, _) => config.windowProps),
    vpnSettingProvider.overrideWithBuild((_, _) => config.vpnProps),
    networkSettingProvider.overrideWithBuild((_, _) => config.networkProps),
    themeSettingProvider.overrideWithBuild((_, _) => config.themeProps),
    currentProfileIdProvider.overrideWithBuild(
      (_, _) => config.currentProfileId,
    ),
    davSettingProvider.overrideWithBuild((_, _) => config.davProps),
    hotKeyActionsProvider.overrideWithBuild((_, _) => config.hotKeyActions),
    proxiesStyleSettingProvider.overrideWithBuild(
      (_, _) => config.proxiesStyleProps,
    ),
    patchClashConfigProvider.overrideWithBuild(
      (_, _) => config.patchClashConfig,
    ),
    excludeSSIDsProvider.overrideWithBuild((_, _) => config.excludeSSIDs),
  ];
}
