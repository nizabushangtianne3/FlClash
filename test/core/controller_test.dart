import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/spill.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../helpers/app_paths.dart';

class MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

void main() {
  late MockCoreHandlerInterface mock;
  late CoreController controller;
  late Directory root;

  setUpAll(() {
    registerFallbackValue(
      const TestDelayParams(proxyName: 'P', testUrl: 'U', timeout: 0),
    );
    registerFallbackValue(
      const SetupParams(
        selectedMap: {},
        options: CoreOptions(testUrl: 'http://x.com'),
      ),
    );
    registerFallbackValue(const InitParams(homeDir: '.', version: 1));
    registerFallbackValue(
      const UpdateParams(
        tun: Tun(),
        mixedPort: 7890,
        allowLan: true,
        findProcessMode: FindProcessMode.off,
        mode: Mode.rule,
        logLevel: LogLevel.info,
        ipv6: false,
        tcpConcurrent: false,
        externalController: ExternalControllerStatus.close,
        unifiedDelay: false,
        options: CoreOptions(testUrl: 'http://x.com'),
      ),
    );
    registerFallbackValue(
      const ChangeProxyParams(groupName: 'G', proxyName: 'P'),
    );
  });

  setUp(() async {
    root = Directory.systemTemp.createTempSync('core_controller_test');
    await useAppPaths(root);
    mock = MockCoreHandlerInterface();
    CoreController.resetInstance();
    controller = CoreController.test(mock);
  });

  tearDown(() {
    CoreController.resetInstance();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  group('CoreController singleton', () {
    test('test constructor injects mock interface', () {
      expect(controller, isA<CoreController>());
    });

    test('resetInstance allows fresh construction', () {
      CoreController.resetInstance();
      final instance = CoreController.test(mock);
      expect(instance, isA<CoreController>());
    });

    test('scoped keeps the supplied interface', () async {
      final scoped = CoreController.scoped(mock);
      when(() => mock.forceGc()).thenAnswer((_) async {});

      expect(scoped, isA<CoreController>());
      await scoped.forceGc();
      verify(() => mock.forceGc()).called(1);
    });
  });

  group('lifecycle methods', () {
    test('start, restart, stop, and close delegate to interface', () async {
      const result = CoreLifecycleResult(
        revision: 1,
        outcome: CoreLifecycleOutcome.applied,
      );
      when(() => mock.start()).thenAnswer((_) async => result);
      when(() => mock.restart()).thenAnswer((_) async => result);
      when(() => mock.stop()).thenAnswer((_) async => result);
      when(() => mock.close()).thenAnswer((_) async => result);

      expect(await controller.start(), same(result));
      expect(await controller.restart(), same(result));
      expect(await controller.stop(), same(result));
      expect(await controller.close(), same(result));

      verify(() => mock.start()).called(1);
      verify(() => mock.restart()).called(1);
      verify(() => mock.stop()).called(1);
      verify(() => mock.close()).called(1);
    });

    test('isInit delegates to interface', () async {
      when(() => mock.isInit).thenAnswer((_) async => true);
      final result = await controller.isInit;
      expect(result, true);
    });

    test('crash delegates to interface', () async {
      when(() => mock.crash()).thenAnswer((_) async {});

      await controller.crash();

      verify(() => mock.crash()).called(1);
    });

    test(
      'init prepares the home directory and delegates to the interface',
      () async {
        for (final fileName in const [MMDB, GEOIP, GEOSITE, ASN]) {
          File(join(root.path, fileName)).writeAsStringSync('data');
        }
        when(() => mock.init(any())).thenAnswer((_) async {});

        await controller.init(7);

        final captured = verify(() => mock.init(captureAny())).captured.single;
        expect(captured, isA<InitParams>());
        expect((captured as InitParams).homeDir, root.path);
        expect(captured.version, 7);
      },
    );
  });

  group('config methods', () {
    test('validateConfig delegates to interface', () async {
      when(() => mock.validateConfig('/path')).thenAnswer((_) async => 'bad');
      final result = await controller.validateConfig('/path');
      expect(result, 'bad');
      verify(() => mock.validateConfig('/path')).called(1);
    });

    group('validateProfile', () {
      late Directory dir;
      late String path;

      setUp(() {
        dir = Directory.systemTemp.createTempSync('validate_profile_test');
        path = '${dir.path}/profile.yaml';
        when(() => mock.validateConfig(path)).thenAnswer((_) async => null);
      });

      tearDown(() => dir.deleteSync(recursive: true));

      test('decrypts an age-encrypted config in place', () async {
        File(
          path,
        ).writeAsStringSync('-----BEGIN AGE ENCRYPTED FILE-----\nYWdl\n');
        when(
          () => mock.decryptConfig(path, 'AGE-SECRET-KEY-1A'),
        ).thenAnswer((_) async => 'proxies: []');

        expect(
          await controller.validateProfile(path, 'AGE-SECRET-KEY-1A'),
          isNull,
        );
        expect(File(path).readAsStringSync(), 'proxies: []');
      });

      test('asks for a key an encrypted config lacks', () async {
        File(
          path,
        ).writeAsStringSync('-----BEGIN AGE ENCRYPTED FILE-----\nYWdl\n');

        await expectLater(
          controller.validateProfile(path),
          throwsA(isA<AgeSecretKeyRequiredException>()),
        );
        verifyNever(() => mock.decryptConfig(any(), any()));
      });

      test('leaves a plain config as it is', () async {
        File(path).writeAsStringSync('proxies: []');

        expect(
          await controller.validateProfile(path, 'AGE-SECRET-KEY-1A'),
          isNull,
        );
        verifyNever(() => mock.decryptConfig(any(), any()));
        expect(File(path).readAsStringSync(), 'proxies: []');
      });

      test('keeps the original issue when proxy conversion fails', () async {
        File(path).writeAsStringSync('proxies: []');
        when(
          () => mock.validateConfig(path),
        ).thenAnswer((_) async => 'invalid');
        when(
          () => mock.convertProxies(path),
        ).thenThrow(Exception('cannot convert'));

        expect(await controller.validateProfile(path), 'invalid');
        expect(File(path).readAsStringSync(), 'proxies: []');
      });

      test(
        'keeps the original issue when conversion finds no proxies',
        () async {
          File(path).writeAsStringSync('proxies: []');
          when(
            () => mock.validateConfig(path),
          ).thenAnswer((_) async => 'invalid');
          when(() => mock.convertProxies(path)).thenAnswer((_) async => []);

          expect(await controller.validateProfile(path), 'invalid');
          expect(File(path).readAsStringSync(), 'proxies: []');
        },
      );

      test('rewrites a share-link list and validates it again', () async {
        File(path).writeAsStringSync('vless://example');
        var validations = 0;
        when(() => mock.validateConfig(path)).thenAnswer((_) async {
          validations++;
          return validations == 1 ? 'invalid' : null;
        });
        when(() => mock.convertProxies(path)).thenAnswer(
          (_) async => [
            {'name': 'Example', 'type': 'vless'},
          ],
        );

        expect(await controller.validateProfile(path), isNull);
        final config = loadYaml(File(path).readAsStringSync()) as YamlMap;
        final proxies = config['proxies'] as YamlList;
        expect(proxies.single['name'], 'Example');
        verify(() => mock.validateConfig(path)).called(2);
      });
    });

    test('updateConfig delegates to interface', () async {
      const params = UpdateParams(
        tun: Tun(enable: false),
        mixedPort: 7890,
        allowLan: true,
        findProcessMode: FindProcessMode.off,
        mode: Mode.rule,
        logLevel: LogLevel.info,
        ipv6: false,
        tcpConcurrent: false,
        externalController: ExternalControllerStatus.close,
        unifiedDelay: false,
        options: CoreOptions(testUrl: 'http://x.com'),
      );
      when(() => mock.updateConfig(params)).thenAnswer((_) async {});
      await controller.updateConfig(params);
      verify(() => mock.updateConfig(params)).called(1);
    });

    test('setupConfig waits for asynchronous preload', () async {
      const params = SetupParams(
        selectedMap: {},
        options: CoreOptions(testUrl: 'http://x.com'),
      );
      final preloadCompleter = Completer<void>();
      final events = <String>[];
      when(() => mock.setupConfig(params)).thenAnswer((_) {
        events.add('setup');
        return Future.value();
      });

      final setupFuture = controller.setupConfig(
        params: params,
        preloadInvoke: () async {
          events.add('preload');
          await preloadCompleter.future;
        },
      );
      var completed = false;
      unawaited(setupFuture.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);

      expect(events, ['setup', 'preload']);
      expect(completed, isFalse);

      preloadCompleter.complete();
      await setupFuture;
      expect(completed, isTrue);
    });

    test('setupConfig delegates directly without a preload', () async {
      const params = SetupParams(
        selectedMap: {},
        options: CoreOptions(testUrl: 'http://x.com'),
      );
      when(() => mock.setupConfig(params)).thenAnswer((_) async {});

      await controller.setupConfig(params: params);

      verify(() => mock.setupConfig(params)).called(1);
    });

    test('validateConfigWithData deletes its temporary file', () async {
      late String validatedPath;
      when(() => mock.validateConfig(any())).thenAnswer((invocation) async {
        validatedPath = invocation.positionalArguments.first as String;
        expect(File(validatedPath).readAsBytesSync(), [1, 2, 3]);
        return 'invalid';
      });

      expect(await controller.validateConfigWithData([1, 2, 3]), 'invalid');
      expect(File(validatedPath).existsSync(), isFalse);
    });

    test(
      'validateConfigWithData deletes its temporary file after failure',
      () async {
        late String validatedPath;
        when(() => mock.validateConfig(any())).thenAnswer((invocation) async {
          validatedPath = invocation.positionalArguments.first as String;
          throw const CoreMethodException(
            code: 'core_error',
            message: 'failed',
          );
        });

        await expectLater(
          controller.validateConfigWithData([1, 2, 3]),
          throwsA(isA<CoreMethodException>()),
        );
        expect(File(validatedPath).existsSync(), isFalse);
      },
    );
  });

  group('proxy methods', () {
    test('changeProxy delegates to interface', () async {
      const params = ChangeProxyParams(groupName: 'G1', proxyName: 'P1');
      const result = ChangeProxyResult(changed: true);
      when(() => mock.changeProxy(params)).thenAnswer((_) async => result);
      expect(await controller.changeProxy(params), result);
    });

    test('watchRoute delegates to interface', () async {
      const snapshot = RouteSnapshot(coreEpoch: 3, routeVersion: 1);
      when(() => mock.watchRoute(true)).thenAnswer((_) async => snapshot);
      expect(await controller.watchRoute(true), snapshot);
    });

    test('checkRoutes delegates to interface', () async {
      const params = CheckRoutesParams(
        routes: [
          [RouteHit(host: 'example.com:443', exit: 'HK-01')],
        ],
      );
      const check = RouteCheck(coreEpoch: 3, routeVersion: 2, held: [true]);
      when(() => mock.checkRoutes(params)).thenAnswer((_) async => check);
      expect(await controller.checkRoutes(params), check);
    });

    test('validateProxies short-circuits an empty list', () async {
      expect(await controller.validateProxies(const []), isEmpty);
      verifyNever(() => mock.validateProxies(any()));
    });

    test('validateProxies delegates a non-empty list', () async {
      const proxies = [
        {'name': 'Example', 'type': 'ss'},
      ];
      when(
        () => mock.validateProxies(proxies),
      ).thenAnswer((_) async => const {0: 'invalid'});

      expect(await controller.validateProxies(proxies), {0: 'invalid'});
      verify(() => mock.validateProxies(proxies)).called(1);
    });

    test('validateFilters short-circuits an empty list', () async {
      expect(await controller.validateFilters(const []), isEmpty);
      verifyNever(() => mock.validateFilters(any()));
    });

    test('validateFilters delegates a non-empty list', () async {
      const filters = ['(hk'];
      when(
        () => mock.validateFilters(filters),
      ).thenAnswer((_) async => const {0: 'invalid'});

      expect(await controller.validateFilters(filters), {0: 'invalid'});
      verify(() => mock.validateFilters(filters)).called(1);
    });

    test('encodeShareLinks short-circuits an empty list', () async {
      expect(await controller.encodeShareLinks(const []), isEmpty);
      verifyNever(() => mock.encodeShareLinks(any()));
    });

    test('encodeShareLinks delegates a non-empty list', () async {
      const proxies = [
        {'name': 'Example', 'type': 'ss'},
      ];
      when(
        () => mock.encodeShareLinks(proxies),
      ).thenAnswer((_) async => ['ss://example']);

      expect(await controller.encodeShareLinks(proxies), ['ss://example']);
      verify(() => mock.encodeShareLinks(proxies)).called(1);
    });

    test('decodeShareLinks short-circuits an empty list', () async {
      expect(await controller.decodeShareLinks(const []), isEmpty);
      verifyNever(() => mock.decodeShareLinks(any()));
    });

    test('decodeShareLinks delegates a non-empty list', () async {
      const lines = ['ss://example'];
      when(() => mock.decodeShareLinks(lines)).thenAnswer(
        (_) async => [
          [
            {'name': 'Example', 'type': 'ss'},
          ],
        ],
      );

      expect(await controller.decodeShareLinks(lines), hasLength(1));
      verify(() => mock.decodeShareLinks(lines)).called(1);
    });

    test('getProxiesGroups converts the Core proxy snapshot', () async {
      when(() => mock.getProxies()).thenAnswer(
        (_) async => const ProxiesData(
          all: ['Selector'],
          proxies: {
            'Selector': {
              'name': 'Selector',
              'type': 'Selector',
              'now': 'Example',
              'all': ['Example'],
            },
            'Example': {'name': 'Example', 'type': 'Direct'},
          },
        ),
      );

      final groups = await controller.getProxiesGroups(
        sortType: ProxiesSortType.none,
        delayMap: const {},
        selectedMap: const {},
        defaultTestUrl: '',
      );

      expect(groups, hasLength(1));
      expect(groups.single.name, 'Selector');
      expect(groups.single.all.single.name, 'Example');
    });
  });

  group('profile methods', () {
    test('readConfig moves the legacy rule field', () async {
      when(() => mock.readConfig(any())).thenAnswer(
        (_) async => {
          'mode': 'rule',
          'rule': ['MATCH,DIRECT'],
        },
      );

      final config = await controller.readConfig(42);

      expect(config['rules'], ['MATCH,DIRECT']);
      expect(config.containsKey('rule'), isFalse);
      verify(
        () => mock.readConfig(join(root.path, 'profiles', '42.yaml')),
      ).called(1);
    });

    test('getProfileOutbounds delegates the profile path', () async {
      when(() => mock.getProfileOutbounds(any())).thenAnswer(
        (_) async => const {
          'proxies': [
            {'name': 'Example', 'type': 'ss'},
          ],
        },
      );

      final outbounds = await controller.getProfileOutbounds(42);

      expect(outbounds['proxies'], hasLength(1));
      verify(
        () => mock.getProfileOutbounds(join(root.path, 'profiles', '42.yaml')),
      ).called(1);
    });

    test('buildProfile reads and deletes the spilled profile', () async {
      const base = SetupBase(path: '/profiles/42.yaml', overlay: 'mode: rule');
      final spillDirectory = Directory(join(root.path, coreSpillDirectoryName))
        ..createSync(recursive: true);
      final built = File(join(spillDirectory.path, 'built.yaml'))
        ..writeAsStringSync('proxies: []');
      when(() => mock.buildProfile(base)).thenAnswer((_) async => built.path);

      expect(await controller.buildProfile(base), 'proxies: []');
      expect(built.existsSync(), isFalse);
    });

    test('getProfileBase removes the legacy rule field', () async {
      when(() => mock.getProfileBase(any())).thenAnswer(
        (_) async => const ProfileBase(
          config: {
            'mode': 'rule',
            'rule': ['MATCH,DIRECT'],
          },
          digest: 'abc',
        ),
      );

      final result = await controller.getProfileBase(42);

      expect(result.base.config['mode'], 'rule');
      expect(result.base.config.containsKey('rule'), isFalse);
      expect(result.path, join(root.path, 'profiles', '42.yaml'));
      verify(
        () => mock.getProfileBase(join(root.path, 'profiles', '42.yaml')),
      ).called(1);
    });
  });

  group('connection methods', () {
    test('getConnections delegates structured connections', () async {
      final connection = TrackerInfo.fromJson({
        'id': '1',
        'metadata': {'network': 'tcp'},
        'upload': 0,
        'download': 0,
        'start': 1704067200000000,
        'chains': ['Proxy'],
        'rule': 'DIRECT',
        'rulePayload': '',
      });
      when(
        () => mock.getConnections(resync: any(named: 'resync')),
      ).thenAnswer((_) async => ConnectionDelta(added: [connection], count: 1));
      final result = await controller.getConnections();
      expect(result.added, hasLength(1));
      expect(result.added.first.id, '1');
    });

    test('getConnections handles empty connections', () async {
      when(
        () => mock.getConnections(resync: any(named: 'resync')),
      ).thenAnswer((_) async => const ConnectionDelta());
      final result = await controller.getConnections();
      expect(result.added, isEmpty);
    });

    test('closeConnection delegates', () async {
      when(() => mock.closeConnection('id1')).thenAnswer((_) async {});
      await controller.closeConnection('id1');
      verify(() => mock.closeConnection('id1')).called(1);
    });
  });

  group('external providers', () {
    test('getExternalProviders delegates structured providers', () async {
      final provider = ExternalProvider(
        name: 'provider1',
        type: 'Proxy',
        count: 5,
        vehicleType: 'HTTP',
        updateAt: DateTime.now(),
      );
      when(
        () => mock.getExternalProviders(),
      ).thenAnswer((_) async => [provider]);
      final result = await controller.getExternalProviders();
      expect(result.length, 1);
      expect(result.first.name, 'provider1');
    });

    test('getExternalProviders handles empty list', () async {
      when(() => mock.getExternalProviders()).thenAnswer((_) async => []);
      final result = await controller.getExternalProviders();
      expect(result, isEmpty);
    });

    test('getExternalProvider returns null when missing', () async {
      when(() => mock.getExternalProvider(any())).thenAnswer((_) async => null);
      final result = await controller.getExternalProvider('test');
      expect(result, isNull);
    });
  });

  group('traffic methods', () {
    test('getTrafficStats delegates structured traffic', () async {
      const stats = TrafficStats(
        now: Traffic(up: 1, down: 2),
        total: Traffic(up: 3, down: 4),
      );
      when(() => mock.getTrafficStats(false)).thenAnswer((_) async => stats);
      final result = await controller.getTrafficStats(false);
      expect(result.now.up, 1);
      expect(result.total.down, 4);
    });

    test('getMemoryStats delegates the structured stats', () async {
      when(
        () => mock.getMemoryStats(),
      ).thenAnswer((_) async => const CoreMemoryStats(rss: 2048));
      final result = await controller.getMemoryStats();
      expect(result.rss, 2048);
    });
  });

  group('misc methods', () {
    test('testDelay delegates structured delay', () async {
      when(() => mock.testDelay(any())).thenAnswer(
        (_) async => const Delay(name: 'P1', value: 100, url: 'test.com'),
      );
      final result = await controller.testDelay(
        const TestDelayParams(
          proxyName: 'P1',
          testUrl: 'test.com',
          timeout: 1000,
        ),
      );
      expect(result.name, 'P1');
      expect(result.value, 100);
    });

    test('listener commands delegate', () async {
      when(() => mock.startListener()).thenAnswer((_) async {});
      when(() => mock.stopListener()).thenAnswer((_) async {});
      await controller.startListener();
      await controller.stopListener();
      verify(() => mock.startListener()).called(1);
      verify(() => mock.stopListener()).called(1);
    });

    test('updateGeoData surfaces what the Core refuses', () async {
      when(() => mock.updateGeoData('MMDB')).thenAnswer(
        (_) async => throw const CoreMethodException(
          code: 'core_error',
          message: 'busy',
        ),
      );
      await expectLater(
        controller.updateGeoData('MMDB'),
        throwsA(isA<CoreMethodException>()),
      );
    });

    test('forceGc delegates', () async {
      when(() => mock.forceGc()).thenAnswer((_) async {});
      await controller.forceGc();
      verify(() => mock.forceGc()).called(1);
    });

    test('clearEffect delegates', () async {
      when(() => mock.clearEffect(42)).thenAnswer((_) async {});
      await controller.clearEffect(42);
      verify(() => mock.clearEffect(42)).called(1);
    });
  });
}
