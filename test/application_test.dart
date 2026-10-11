import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/application.dart';
import 'package:fl_clash/manager/hotkey_manager.dart';
import 'package:fl_clash/manager/manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

const _leaf = SizedBox.shrink();

Widget? _childOf(Widget widget) {
  return switch (widget) {
    AppEnvManager(:final child) => child,
    LocaleManager(:final child) => child,
    StatusManager(:final child) => child,
    ThemeManager(:final child) => child,
    WindowManager(:final child) => child,
    TrayManager(:final child) => child,
    HotKeyManager(:final child) => child,
    ProxyManager(:final child) => child,
    AndroidManager(:final child) => child,
    TileManager(:final child) => child,
    AppStateManager(:final child) => child,
    CoreManager(:final child) => child,
    ConnectivityManager(:final child) => child,
    WindowHeaderContainer(:final child) => child,
    VpnManager(:final child) => child,
    _ => null,
  };
}

List<Type> _chainFrom(Widget root) {
  final types = <Type>[];
  Widget? current = root;
  while (current != null && current is! SizedBox) {
    types.add(current.runtimeType);
    current = _childOf(current);
  }
  return types;
}

Widget? _innermostChildOf(Widget root) {
  Widget? current = root;
  Widget? previous;
  while (current != null && current is! SizedBox) {
    previous = current;
    current = _childOf(current);
  }
  return current ?? previous;
}

Widget _stack({required bool isDesktop}) {
  return buildManagerStack(
    isDesktop: isDesktop,
    onConnectivityChanged: (_) async {},
    child: _leaf,
  );
}

void main() {
  test('the desktop manager stack nests in ownership order', () {
    expect(_chainFrom(_stack(isDesktop: true)), [
      AppEnvManager,
      LocaleManager,
      StatusManager,
      ThemeManager,
      WindowManager,
      TrayManager,
      HotKeyManager,
      ProxyManager,
      AppStateManager,
      CoreManager,
      ConnectivityManager,
      WindowHeaderContainer,
    ]);
  });

  test('the mobile manager stack nests in ownership order', () {
    expect(_chainFrom(_stack(isDesktop: false)), [
      AppEnvManager,
      LocaleManager,
      StatusManager,
      ThemeManager,
      AndroidManager,
      TileManager,
      AppStateManager,
      CoreManager,
      ConnectivityManager,
      VpnManager,
    ]);
  });

  test('desktop-only managers never appear on mobile', () {
    final mobile = _chainFrom(_stack(isDesktop: false));

    expect(
      mobile,
      isNot(
        anyOf(
          contains(WindowManager),
          contains(TrayManager),
          contains(HotKeyManager),
          contains(ProxyManager),
          contains(WindowHeaderContainer),
        ),
      ),
    );
  });

  test('mobile-only managers never appear on desktop', () {
    final desktop = _chainFrom(_stack(isDesktop: true));

    expect(
      desktop,
      isNot(
        anyOf(
          contains(AndroidManager),
          contains(TileManager),
          contains(VpnManager),
        ),
      ),
    );
  });

  test('Core is mounted before the connectivity callback can fire', () {
    for (final isDesktop in [true, false]) {
      final chain = _chainFrom(_stack(isDesktop: isDesktop));

      expect(
        chain.indexOf(CoreManager),
        lessThan(chain.indexOf(ConnectivityManager)),
        reason: 'connectivity changes read Core-backed state',
      );
    }
  });

  test('the app content stays the innermost child', () {
    for (final isDesktop in [true, false]) {
      expect(
        _innermostChildOf(_stack(isDesktop: isDesktop)),
        same(_leaf),
        reason: 'every manager must wrap the app content, not replace it',
      );
    }
  });

  group('profile auto update scheduling', () {
    final now = DateTime.utc(2026, 10, 7, 1);

    test('holds only the failed profile back while it still waits', () {
      final profiles = [
        Profile(
          id: 1,
          url: 'https://example.com/a',
          autoUpdateDuration: const Duration(hours: 1),
          lastUpdateDate: now.subtract(const Duration(hours: 2)),
        ),
      ];

      expect(
        nextAutoUpdateSweepDelay(
          profiles: profiles,
          now: now,
          retryNotBefore: {1: now.add(const Duration(minutes: 5))},
        ),
        const Duration(minutes: 5),
      );
      expect(
        nextAutoUpdateSweepDelay(
          profiles: profiles,
          now: now,
          retryNotBefore: {1: now.subtract(const Duration(minutes: 1))},
        ),
        Duration.zero,
      );
    });

    test('a healthy profile keeps its own update time during a retry', () {
      final failed = Profile(
        id: 1,
        url: 'https://example.com/a',
        autoUpdateDuration: const Duration(hours: 1),
        lastUpdateDate: now.subtract(const Duration(hours: 2)),
      );
      final healthy = Profile(
        id: 2,
        url: 'https://example.com/b',
        autoUpdateDuration: const Duration(minutes: 30),
        lastUpdateDate: now,
      );

      expect(
        nextAutoUpdateSweepDelay(
          profiles: [failed, healthy],
          now: now,
          retryNotBefore: {failed.id: now.add(const Duration(hours: 1))},
        ),
        const Duration(minutes: 30),
      );

      final dueHealthy = healthy.copyWith(
        lastUpdateDate: now.subtract(const Duration(minutes: 31)),
      );
      expect(
        nextAutoUpdateSweepDelay(
          profiles: [failed, dueHealthy],
          now: now,
          retryNotBefore: {failed.id: now.add(const Duration(hours: 1))},
        ),
        Duration.zero,
      );
    });

    test('lets a later due time win over the floor', () {
      expect(
        nextAutoUpdateSweepDelay(
          profiles: [
            Profile(
              id: 1,
              url: 'https://example.com/a',
              autoUpdateDuration: const Duration(hours: 1),
              lastUpdateDate: now,
            ),
          ],
          now: now,
          retryNotBefore: const {},
        ),
        const Duration(hours: 1),
      );
      expect(
        nextAutoUpdateSweepDelay(
          profiles: const [],
          now: now,
          retryNotBefore: const {},
        ),
        isNull,
      );
    });

    test('a regained network clears the failed-sweep backoff', () {
      expect(
        connectivityBecameAvailable(
          {ConnectivityResult.none},
          {ConnectivityResult.wifi},
        ),
        isTrue,
      );
      expect(
        connectivityBecameAvailable(
          {ConnectivityResult.wifi},
          {ConnectivityResult.mobile},
        ),
        isFalse,
      );
      expect(
        connectivityBecameAvailable(
          {ConnectivityResult.none},
          {ConnectivityResult.none},
        ),
        isFalse,
      );
      expect(
        connectivityBecameAvailable(const {}, {ConnectivityResult.wifi}),
        isFalse,
      );
    });

    test('only subscription changes clear a profile retry', () {
      final first = Profile.normal(label: 'One', url: 'https://example.com/a');
      final second = Profile.normal(label: 'Two', url: 'https://example.com/b');
      final profiles = [first, second];

      expect(
        changedAutoUpdateProfileIds(profiles, [
          first.copyWith(selectedMap: const {'Group': 'Proxy'}),
          second,
        ]),
        isEmpty,
      );
      expect(
        changedAutoUpdateProfileIds(profiles, [
          first.copyWith(url: 'https://example.com/changed'),
          second,
        ]),
        {first.id},
      );
      expect(
        changedAutoUpdateProfileIds(profiles, [
          first.copyWith(autoUpdate: false),
          second,
        ]),
        {first.id},
      );
      expect(changedAutoUpdateProfileIds(profiles, [second]), {first.id});
      expect(
        changedAutoUpdateProfileIds(profiles, [
          first,
          second,
          Profile.normal(label: 'Three', url: 'https://example.com/c'),
        ]),
        isNotEmpty,
      );
    });
  });

  group('profile auto update retry', () {
    test('doubles the wait and stops at an hour', () {
      var wait = const Duration(minutes: 5);
      final waits = <Duration>[];

      for (var attempt = 0; attempt < 6; attempt++) {
        wait = nextAutoUpdateRetryDelay(wait);
        waits.add(wait);
      }

      expect(waits, [
        const Duration(minutes: 10),
        const Duration(minutes: 20),
        const Duration(minutes: 40),
        const Duration(hours: 1),
        const Duration(hours: 1),
        const Duration(hours: 1),
      ]);
    });
  });
}
