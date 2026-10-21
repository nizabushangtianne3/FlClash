import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/http.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

class _FakeCertificate implements X509Certificate {
  @override
  String get issuer => 'CN=Untrusted';

  @override
  String get subject => 'CN=example.com';

  @override
  DateTime get startValidity => DateTime(2026);

  @override
  DateTime get endValidity => DateTime(2027);

  @override
  Uint8List get der => Uint8List(0);

  @override
  String get pem => '';

  @override
  Uint8List get sha1 => Uint8List(0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer buildContainer({
    bool running = true,
    String? currentSsid,
    List<String> excludeSSIDs = const [],
    int mixedPort = 7890,
    bool checkCertificate = true,
  }) {
    final container = ProviderContainer(
      overrides: [excludeSSIDsProvider.overrideWithValue(excludeSSIDs)],
    );
    addTearDown(container.dispose);
    container.read(runTimeProvider.notifier).value = running ? 1 : null;
    container.read(currentSSIDProvider.notifier).value = currentSsid;
    container.read(patchClashConfigProvider.notifier).value =
        const PatchClashConfig().copyWith(mixedPort: mixedPort);
    container.read(appSettingProvider.notifier).value = const AppSettingProps()
        .copyWith(checkCertificate: checkCertificate);
    return container;
  }

  final remote = Uri.parse('https://example.com/path');

  test('loopback traffic always bypasses the proxy', () {
    final container = buildContainer();

    expect(
      FlClashHttpOverrides.findProxyFor(
        container,
        Uri.parse('http://$localhost:9090/ui'),
      ),
      'DIRECT',
    );
  });

  test('routes through the mixed port while the core is running', () {
    final container = buildContainer(mixedPort: 7891);

    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY localhost:7891',
    );
  });

  test('carries credentials when local authentication is enabled', () {
    final container = buildContainer();
    container.read(networkSettingProvider.notifier).value = const NetworkProps()
        .copyWith(
          authentication: const AuthenticationProps(
            enable: true,
            username: 'user',
            password: 'pass',
          ),
        );

    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY user:pass@localhost:7890',
    );

    container.read(networkSettingProvider.notifier).value = const NetworkProps()
        .copyWith(
          authentication: const AuthenticationProps(
            enable: false,
            username: 'user',
          ),
        );
    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY localhost:7890',
    );
  });

  test('bypasses the proxy when the core is not running', () {
    final container = buildContainer(running: false);

    expect(FlClashHttpOverrides.findProxyFor(container, remote), 'DIRECT');
  });

  test('bypasses the proxy on an excluded SSID', () {
    final container = buildContainer(
      currentSsid: 'Office Wi-Fi',
      excludeSSIDs: const ['Office Wi-Fi'],
    );

    expect(FlClashHttpOverrides.findProxyFor(container, remote), 'DIRECT');
  });

  test('keeps proxying when the current SSID is not excluded', () {
    final container = buildContainer(
      currentSsid: 'Home Wi-Fi',
      excludeSSIDs: const ['Office Wi-Fi'],
    );

    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY localhost:7890',
    );
  });

  test('bypasses the hosts the bypass list names', () {
    final container = buildContainer();

    expect(
      FlClashHttpOverrides.findProxyFor(
        container,
        Uri.parse('http://localhost:9090/ui'),
      ),
      'DIRECT',
    );

    for (final host in ['www.zhihu.com', 'nas.local']) {
      expect(
        FlClashHttpOverrides.findProxyFor(
          container,
          Uri.parse('https://$host'),
        ),
        'DIRECT',
        reason: host,
      );
    }
  });

  test('a bare bypass name covers the host and its subdomains only', () {
    final container = buildContainer();
    container.read(networkSettingProvider.notifier).value = const NetworkProps()
        .copyWith(bypassDomain: const ['nas.lan']);

    for (final host in ['nas.lan', 'files.nas.lan']) {
      expect(
        FlClashHttpOverrides.findProxyFor(
          container,
          Uri.parse('https://$host'),
        ),
        'DIRECT',
        reason: host,
      );
    }

    expect(
      FlClashHttpOverrides.findProxyFor(
        container,
        Uri.parse('https://notnas.lan'),
      ),
      'PROXY localhost:7890',
    );
  });

  test('bypasses private hosts while the private route is bypassed', () {
    final container = buildContainer();
    container.read(networkSettingProvider.notifier).value = const NetworkProps()
        .copyWith(bypassDomain: const []);

    for (final host in ['10.0.0.5', '192.168.1.10']) {
      expect(
        FlClashHttpOverrides.findProxyFor(
          container,
          Uri.parse('https://$host'),
        ),
        'DIRECT',
        reason: host,
      );
    }

    for (final host in ['fc00::1', 'fe80::1']) {
      expect(
        FlClashHttpOverrides.findProxyFor(
          container,
          Uri.parse('https://[$host]'),
        ),
        'DIRECT',
        reason: host,
      );
    }

    expect(
      FlClashHttpOverrides.findProxyFor(
        container,
        Uri.parse('https://1.1.1.1'),
      ),
      'PROXY localhost:7890',
    );
  });

  test('keeps sending private hosts through the Core on request', () {
    final container = buildContainer();
    container.read(networkSettingProvider.notifier).value = const NetworkProps()
        .copyWith(bypassDomain: const [], bypassPrivateRoute: false);

    expect(
      FlClashHttpOverrides.findProxyFor(
        container,
        Uri.parse('https://192.168.1.10'),
      ),
      'PROXY localhost:7890',
    );
  });

  test('follows a port change after the first lookup', () {
    final container = buildContainer();

    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY localhost:7890',
    );

    container.read(patchClashConfigProvider.notifier).value =
        const PatchClashConfig().copyWith(mixedPort: 9091);

    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY localhost:9091',
    );
  });

  test('an untrusted certificate is rejected by default', () {
    final container = buildContainer();

    expect(
      FlClashHttpOverrides.allowBadCertificate(
        container,
        _FakeCertificate(),
        'example.com',
        443,
      ),
      isFalse,
    );
  });

  test('turning the check off accepts an untrusted certificate', () {
    final container = buildContainer(checkCertificate: false);

    expect(
      FlClashHttpOverrides.allowBadCertificate(
        container,
        _FakeCertificate(),
        'example.com',
        443,
      ),
      isTrue,
    );
  });
}
