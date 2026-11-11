import 'dart:io';

import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockFile extends Mock implements File {}

void main() {
  group('FileInfo', () {
    late MockFile file;

    setUp(() {
      file = MockFile();
    });

    test('reads size and valid last modified time', () async {
      final lastModified = DateTime(2026, 7, 29);
      when(() => file.exists()).thenAnswer((_) async => true);
      when(() => file.length()).thenAnswer((_) async => 2048);
      when(() => file.lastModified()).thenAnswer((_) async => lastModified);

      final fileInfo = await file.getFileInfo();

      expect(fileInfo, FileInfo(size: 2048, lastModified: lastModified));
    });

    test(
      'treats positive timestamps within the epoch year as unknown',
      () async {
        when(() => file.exists()).thenAnswer((_) async => true);
        when(() => file.length()).thenAnswer((_) async => 1024);
        when(
          () => file.lastModified(),
        ).thenAnswer((_) async => DateTime(1970, 12, 31, 23, 59, 59));

        final fileInfo = await file.getFileInfo();

        expect(fileInfo, const FileInfo(size: 1024));
      },
    );

    test('keeps size when last modified time cannot be read', () async {
      when(() => file.exists()).thenAnswer((_) async => true);
      when(() => file.length()).thenAnswer((_) async => 1024);
      when(
        () => file.lastModified(),
      ).thenThrow(const FileSystemException('last modified unavailable'));

      final fileInfo = await file.getFileInfo();

      expect(fileInfo, const FileInfo(size: 1024));
    });

    test('returns null when file does not exist', () async {
      when(() => file.exists()).thenAnswer((_) async => false);

      expect(await file.getFileInfo(), isNull);
      verifyNever(() => file.length());
      verifyNever(() => file.lastModified());
    });
  });

  group('PackagesExt', () {
    const packages = [
      Package(
        packageName: 'system.app',
        label: 'System',
        system: true,
        internet: true,
        lastUpdateTime: 1,
      ),
      Package(
        packageName: 'user.old',
        label: 'Alpha',
        system: false,
        internet: false,
        lastUpdateTime: 2,
      ),
      Package(
        packageName: 'user.new',
        label: 'Beta',
        system: false,
        internet: true,
        lastUpdateTime: 3,
      ),
    ];

    test('filters system and non-internet apps', () {
      final result = packages.getViewList(
        pinedList: [],
        sortType: AccessSortType.none,
        isFilterSystemApp: true,
        isFilterNonInternetApp: true,
      );

      expect(result.map((item) => item.packageName), ['user.new']);
    });

    test('pins selected packages before sorted packages', () {
      final result = packages.getViewList(
        pinedList: ['user.old'],
        sortType: AccessSortType.name,
        isFilterSystemApp: false,
        isFilterNonInternetApp: false,
      );

      expect(result.map((item) => item.packageName), [
        'user.old',
        'user.new',
        'system.app',
      ]);
    });
  });

  group('TrackerInfoExt', () {
    test('builds destination title and process text', () {
      final trackerInfo = TrackerInfo(
        id: '1',
        start: DateTime(2026),
        metadata: const Metadata(
          network: 'tcp',
          host: 'example.com',
          destinationIP: '1.1.1.1',
          destinationPort: '443',
          process: 'Browser',
          uid: 501,
        ),
        chains: const ['Proxy'],
        rule: 'MATCH',
        rulePayload: '',
      );

      expect(trackerInfo.title, 'example.com');
      expect(trackerInfo.progressText, 'Browser(501)');

      final other = trackerInfo.copyWith(
        rule: 'DOMAIN-SUFFIX',
        rulePayload: 'example.com',
        metadata: const Metadata(network: 'tcp', process: 'Browser'),
      );
      expect(other.progressText, 'Browser');
      expect(other.ruleText, 'DOMAIN-SUFFIX(example.com)');
      expect(trackerInfo.ruleText, 'MATCH');
    });
  });

  group('TrafficExt', () {
    test('formats tray title and total speed', () {
      const traffic = Traffic(up: 1024, down: 2048);

      expect(traffic.trayTitle, '1 KB/s\n2 KB/s');
      expect(traffic.speed, 3072);
    });
  });

  group('GroupsExt', () {
    test('finds group by name and resolves current selection', () {
      const groups = [
        Group(name: 'Auto', type: GroupType.URLTest, now: 'Proxy A'),
        Group(name: 'Manual', type: GroupType.Selector, now: 'Proxy B'),
      ];

      expect(
        groups.getGroup('Auto')?.getCurrentSelectedName('Proxy C'),
        'Proxy A',
      );
      expect(
        groups.getGroup('Manual')?.getCurrentSelectedName('Proxy C'),
        'Proxy C',
      );
      expect(groups.getGroup('Missing'), isNull);
    });
  });

  group('ScriptsExt naming', () {
    Script script(int id, String label) =>
        Script(id: id, label: label, lastUpdateTime: DateTime(2026));

    test('hasLabel ignores the script being renamed', () {
      final scripts = [script(1, 'a'), script(2, 'b')];
      expect(scripts.hasLabel('a'), isTrue);
      expect(scripts.hasLabel('a', except: scripts[0]), isFalse);
      expect(scripts.hasLabel('a', except: scripts[1]), isTrue);
      expect(scripts.hasLabel('c'), isFalse);
    });

    test('uniqueLabel trims, falls back and numbers duplicates', () {
      final scripts = [script(1, 'remote'), script(2, 'remote(1)')];
      expect(scripts.uniqueLabel(' local ', fallback: 'Script'), 'local');
      expect(scripts.uniqueLabel('remote', fallback: 'Script'), 'remote(2)');
      expect(scripts.uniqueLabel('   ', fallback: 'Script'), 'Script');
      expect(
        [script(3, 'Script')].uniqueLabel('', fallback: 'Script'),
        'Script(1)',
      );
    });

    test('uniqueLabel keeps the numbered label within the name limit', () {
      final long = 'x' * 100;
      final scripts = [script(1, 'x' * TextInputLimits.name)];
      final label = scripts.uniqueLabel(long, fallback: 'Script');
      expect(label.length, lessThanOrEqualTo(TextInputLimits.name));
      expect(label, endsWith('(1)'));
      expect(scripts.hasLabel(label), isFalse);
    });
  });

  group('IpInfo parsers', () {
    test('parse supported response shapes', () {
      expect(
        IpInfo.fromIpInfoIoJson({'ip': '1.1.1.1', 'country': 'US'}),
        const IpInfo(ip: '1.1.1.1', countryCode: 'US'),
      );
      expect(
        IpInfo.fromIdentMeJson({'ip': '2.2.2.2', 'cc': 'JP'}),
        const IpInfo(ip: '2.2.2.2', countryCode: 'JP'),
      );
      expect(
        IpInfo.fromGeoJsJson({'ip': '4.4.4.4', 'country_code': 'DE'}),
        const IpInfo(ip: '4.4.4.4', countryCode: 'DE'),
      );
      expect(
        IpInfo.fromCountryIsJson({'ip': '5.5.5.5', 'country': 'FR'}),
        const IpInfo(ip: '5.5.5.5', countryCode: 'FR'),
      );
    });

    test('parse the ipquery.io country from its location object', () {
      expect(
        IpInfo.fromIpQueryJson({
          'ip': '203.0.113.9',
          'isp': {'asn': 'AS64500', 'org': '', 'isp': 'Example'},
          'location': {'country': 'United Kingdom', 'country_code': 'GB'},
          'risk': {'is_datacenter': false},
        }),
        const IpInfo(ip: '203.0.113.9', countryCode: 'GB'),
      );
    });

    test('parse the Cloudflare trace key-value text', () {
      expect(
        IpInfo.fromCloudflareTrace(
          'fl=0f0\nh=www.cloudflare.com\nip=203.0.113.9\nts=1757800000.1\n'
          'visit_scheme=https\ncolo=LHR\nhttp=http/2\nloc=GB\ntls=TLSv1.3\n',
        ),
        const IpInfo(ip: '203.0.113.9', countryCode: 'GB'),
      );
    });

    test('throw FormatException for unsupported response shapes', () {
      expect(
        () => IpInfo.fromIpInfoIoJson({'ip': '1.1.1.1'}),
        throwsFormatException,
      );
      expect(
        () => IpInfo.fromGeoJsJson({'ip': '1.1.1.1'}),
        throwsFormatException,
      );
      expect(
        () => IpInfo.fromIpQueryJson({
          'ip': '1.1.1.1',
          'location': <String, dynamic>{},
        }),
        throwsFormatException,
      );
      expect(
        () => IpInfo.fromCloudflareTrace('ip=1.1.1.1\ncolo=LHR\n'),
        throwsFormatException,
      );
    });
  });

  group('ResultExt', () {
    test('identifies success and error results', () {
      final success = Result.success('ok');
      final error = Result<Object>.error('failed');

      expect(success.isSuccess, isTrue);
      expect(success.isError, isFalse);
      expect(error.isSuccess, isFalse);
      expect(error.isError, isTrue);
    });
  });

  group('parseIconSet', () {
    test('reads the name and icons of a gallery subscription', () {
      final parsed = parseIconSet(
        '{"name": " Qure ", "description": "x", "icons": ['
        '{"name": "Hong_Kong.png", "url": "https://example.com/hk.png"},'
        '{"url": "https://example.com/Japan.svg?raw=true"}'
        ']}',
      );

      expect(parsed.name, 'Qure');
      expect(parsed.icons, const [
        IconSetIcon(name: 'Hong_Kong.png', url: 'https://example.com/hk.png'),
        IconSetIcon(
          name: 'Japan.svg',
          url: 'https://example.com/Japan.svg?raw=true',
        ),
      ]);
      expect(parsed.icons.first.label, 'Hong Kong');
    });

    test('drops entries without an http url and repeated urls', () {
      final parsed = parseIconSet(
        '{"icons": ['
        '{"name": "a", "url": "https://example.com/a.png"},'
        '{"name": "again", "url": "https://example.com/a.png"},'
        '{"name": "ftp", "url": "ftp://example.com/b.png"},'
        '{"name": "relative", "url": "c.png"},'
        '{"name": "missing"},'
        '"https://example.com/d.png"'
        ']}',
      );

      expect(parsed.name, isEmpty);
      expect(parsed.icons.map((icon) => icon.name), ['a']);
    });

    test('rejects documents that are not icon sets', () {
      for (final content in [
        'not json',
        '[]',
        '{"name": "x"}',
        '{"icons": [{"name": "x", "url": "file:///x.png"}]}',
      ]) {
        expect(
          () => parseIconSet(content),
          throwsFormatException,
          reason: content,
        );
      }
    });
  });

  group('logFromData', () {
    test('reads the level, payload and the batch clock it is handed', () {
      final now = DateTime.utc(2026, 11, 11, 7);
      final log = logFromData({
        'LogLevel': 'warning',
        'Payload': '[TCP] dial error',
      }, now);

      expect(log.logLevel, LogLevel.warning);
      expect(log.payload, '[TCP] dial error');
      expect(log.dateTime, same(now));
    });

    test('defaults an absent payload and an unknown level', () {
      final log = logFromData({'LogLevel': 'verbose'}, DateTime.utc(2026));

      expect(log.payload, isEmpty);
      expect(log.logLevel, LogLevel.info);
    });

    test('names every level the core writes', () {
      for (final level in LogLevel.values) {
        expect(logLevelOf(level.name), level, reason: level.name);
      }
      expect(logLevelOf(null), isNull);
      expect(logLevelOf('verbose'), isNull);
    });
  });

  group('trackerInfoFromData', () {
    Map<String, Object?> fullRowMap() {
      return {
        'id': 'c-1',
        'upload': 11,
        'download': 22,
        'start': 1789705801000000,
        'metadata': const {
          'uid': 1000,
          'network': 'tcp',
          'sourceIP': '192.168.1.2',
          'sourcePort': '51000',
          'destinationIP': '1.2.3.4',
          'destinationPort': '443',
          'host': 'example.com',
          'dnsMode': 'fake-ip',
          'process': 'chrome',
          'processPath': '/usr/bin/chrome',
          'remoteDestination': '5.6.7.8:443',
          'sourceGeoIP': ['CN', 'HK'],
          'destinationGeoIP': ['US'],
          'destinationIPASN': 'AS15169',
          'sourceIPASN': 'AS4134',
          'specialRules': 'rule-a',
          'specialProxy': 'Proxy',
          'mitm': true,
          'mitmRefused': true,
        },
        'chains': ['Proxy-A', 'Proxy-B'],
        'rule': 'Rule-Set',
        'rulePayload': 'example.com',
        'downloadSpeed': 100,
        'uploadSpeed': 200,
      };
    }

    test('reads a row the generated reader and it agree on', () {
      final map = fullRowMap();
      final row = trackerInfoFromData(map);

      expect(row, TrackerInfo.fromJson(map));
      expect(row.metadata.dnsMode, DnsMode.fakeIp);
      expect(row.metadata.sourceGeoIP, ['CN', 'HK']);
      expect(row.chains, ['Proxy-A', 'Proxy-B']);
      expect(row.downloadSpeed, 100);
      expect(row.uploadSpeed, 200);
    });

    test('fills defaults where the wire leaves a field out', () {
      final map = {
        'id': 'c-2',
        'start': 1789705801000000,
        'metadata': const {'network': 'udp'},
        'chains': const <String>[],
        'rule': 'MATCH',
        'rulePayload': '',
      };
      final row = trackerInfoFromData(map);

      expect(row.upload, 0);
      expect(row.download, 0);
      expect(row.downloadSpeed, isNull);
      expect(row.metadata.uid, 0);
      expect(row.metadata.host, isEmpty);
      expect(row.metadata.dnsMode, isNull);
      expect(row.metadata.mitm, isFalse);
      expect(row.chains, isEmpty);
      expect(row, TrackerInfo.fromJson(map));
    });

    test('names every dns mode the core writes', () {
      for (final mode in DnsMode.values) {
        final row = trackerInfoFromData({
          'id': 'c-3',
          'start': 1789705801000000,
          'metadata': {
            'dnsMode': switch (mode) {
              DnsMode.fakeIp => 'fake-ip',
              DnsMode.redirHost => 'redir-host',
              _ => mode.name,
            },
          },
          'chains': const <String>[],
          'rule': 'MATCH',
          'rulePayload': '',
        });

        expect(row.metadata.dnsMode, mode, reason: mode.name);
      }
      expect(dnsModeOf(null), isNull);
      expect(dnsModeOf('bogus'), isNull);
    });

    test('matches the generated reader on randomized presence', () {
      final random = Random(42);
      const metadataKeys = [
        'uid',
        'network',
        'sourceIP',
        'sourcePort',
        'destinationIP',
        'destinationPort',
        'host',
        'dnsMode',
        'process',
        'processPath',
        'remoteDestination',
        'sourceGeoIP',
        'destinationGeoIP',
        'destinationIPASN',
        'sourceIPASN',
        'specialRules',
        'specialProxy',
        'mitm',
        'mitmRefused',
      ];
      const dnsModes = ['normal', 'fake-ip', 'redir-host', 'hosts'];
      Object? sample(String key) => switch (key) {
        'uid' => random.nextInt(10000),
        'dnsMode' => dnsModes[random.nextInt(dnsModes.length)],
        'sourceGeoIP' || 'destinationGeoIP' => List.generate(
          random.nextInt(3),
          (_) => 'AS${random.nextInt(999)}',
        ),
        'mitm' || 'mitmRefused' => random.nextBool(),
        _ => 'v-${random.nextInt(999)}',
      };

      for (var attempt = 0; attempt < 200; attempt++) {
        final metadata = <String, Object?>{
          for (final key in metadataKeys)
            if (random.nextBool()) key: sample(key),
        };
        final row = <String, Object?>{
          'id': 'c-$attempt',
          'start': 1789705801000000 + attempt,
          'metadata': metadata,
          // The core writes chains on every row; the generated reader
          // requires it, so the fuzz holds the wire's always-present piece.
          'chains': List.generate(
            random.nextInt(3),
            (_) => 'Proxy-${random.nextInt(9)}',
          ),
          'rule': 'MATCH',
          'rulePayload': '',
        };
        if (random.nextBool()) row['upload'] = random.nextInt(9999);
        if (random.nextBool()) row['download'] = random.nextInt(9999);
        if (random.nextBool()) row['downloadSpeed'] = random.nextInt(9999);
        if (random.nextBool()) row['uploadSpeed'] = random.nextInt(9999);

        expect(
          trackerInfoFromData(row),
          TrackerInfo.fromJson(row),
          reason: 'row $attempt: $row',
        );
      }
    });
  });
}
