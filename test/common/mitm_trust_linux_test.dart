@TestOn('linux')
library;

import 'dart:io';

import 'package:fl_clash/common/mitm_trust.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

// The Linux store answers a POSIX PATH and a /bin/sh elevation, so its
// fixtures are kept apart from the other stores: on a host that spells
// paths differently the search path it splits never reaches the stubs.

const _pem = '''-----BEGIN CERTIFICATE-----
MIIBxjCCAW2gAwIBAgIUE7mKNCkR6iuATGzZPqCqjJNFbKswCgYIKoZIzj0EAwIw
MDEQMA4GA1UECgwHRmxDbGFzaDEcMBoGA1UEAwwTRmxDbGFzaCBDQSBURVNUMDAw
MTAgFw0yNjEwMjQxNjUzMTRaGA8yMTI2MDkzMDE2NTMxNFowMDEQMA4GA1UECgwH
RmxDbGFzaDEcMBoGA1UEAwwTRmxDbGFzaCBDQSBURVNUMDAwMTBZMBMGByqGSM49
AgEGCCqGSM49AwEHA0IABNn15sIzPbxvIn77jfHEL4v74KwWE39G7UhONuQavnNQ
Z8ozH+LJNXhfZ6E990ijPShyDUPcbGz8IUs0FkW46qWjYzBhMB0GA1UdDgQWBBTB
xMV0LGSPvHhH2n4Mg4I8o7ZSYjAfBgNVHSMEGDAWgBTBxMV0LGSPvHhH2n4Mg4I8
o7ZSYjAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQD
AgNHADBEAiBjQdoVkwyA4Zdcrh1gSvx2PDQO6AxrH90fxTt4ZvNEIAIgBg80krDn
billN9o10i2kxHN/yZkuSW4xpVUtd6kxP2s=
-----END CERTIFICATE-----
''';

final _ca = MitmCertificate(
  pem: _pem,
  fingerprint:
      '56:84:B9:9A:4C:8E:9C:B4:F3:63:94:25:A5:D2:B6:1C:'
      '2D:4B:05:C6:53:15:36:26:8B:AC:4A:2F:D7:37:8D:17',
  subject: 'FlClash CA TEST0001',
  notBefore: DateTime.utc(2026, 10, 24),
  notAfter: DateTime.utc(2126, 9, 30),
);

class _Run {
  const _Run(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

class _Processes {
  final runs = <_Run>[];
  final _results = <String, (int, String)>{};
  final _handlers = <String, ProcessResult Function(List<String> arguments)>{};

  void handle(
    String executable,
    ProcessResult Function(List<String> arguments) handler,
  ) {
    _handlers[executable] = handler;
  }

  /// Answers runs whose command line starts with [prefix].
  void stub(String prefix, {int exitCode = 0, String stdout = ''}) {
    _results[prefix] = (exitCode, stdout);
  }

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    runs.add(_Run(executable, arguments));
    if (_handlers[executable] case final handler?) {
      return handler(arguments);
    }
    final line = [executable, ...arguments].join(' ');
    final match = _results.keys
        .where(line.startsWith)
        .fold<String?>(
          null,
          (best, key) => best == null || key.length > best.length ? key : best,
        );
    final (exitCode, stdout) = _results[match] ?? (0, '');
    return ProcessResult(0, exitCode, stdout, exitCode == 0 ? '' : 'failed');
  }

  List<List<String>> argumentsOf(String executable) => [
    for (final run in runs)
      if (run.executable == executable) run.arguments,
  ];
}

void main() {
  late Directory root;
  late _Processes processes;
  late List<String> written;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mitm_trust_test');
    processes = _Processes();
    written = [];
  });

  tearDown(() => root.delete(recursive: true));

  Future<String> writeTemp(String content) async {
    final file = File('${root.path}/temp-${written.length}.pem');
    await file.writeAsString(content);
    written.add(content);
    return file.path;
  }

  Future<String> issueLeaf() async => 'leaf pem';

  group('Linux', () {
    late Map<String, String> files;
    late Map<String, List<String>> directories;
    late List<List<String>> elevated;
    late bool elevation;

    setUp(() {
      files = {};
      directories = {};
      elevated = [];
      elevation = true;
    });

    Future<void> touch(String path) async {
      await File('${root.path}$path').create(recursive: true);
    }

    LinuxMitmTrustStore store({bool certutil = true}) {
      final bin = Directory('${root.path}/bin')..createSync(recursive: true);
      if (certutil) {
        File('${bin.path}/certutil').createSync();
      }
      return LinuxMitmTrustStore(
        home: '${root.path}/home',
        searchPath: '/nonexistent:${bin.path}',
        run: processes.run,
        elevate: (command) async {
          elevated.add(command);
          return elevation;
        },
        writeTemp: writeTemp,
        readFile: (path) async => files[path],
        listDirectory: (path) async => directories[path] ?? const [],
      );
    }

    String database(String path) => '${root.path}/home$path';

    group('removing', () {
      void listDatabases({required bool stays}) {
        var deleted = false;
        processes.handle('${root.path}/bin/certutil', (arguments) {
          if (arguments.contains('-D')) {
            deleted = true;
            return ProcessResult(0, 0, '', '');
          }
          return deleted && !stays
              ? ProcessResult(0, 255, '', 'not found')
              : ProcessResult(0, 0, _pem, '');
        });
      }

      test('takes the CA out of the bundle and each browser', () async {
        files[LinuxMitmTrustStore.bundles.first] = _pem;
        await touch('/home/.pki/nssdb/cert9.db');
        listDatabases(stays: false);

        expect(await store().remove(_ca), isTrue);

        expect(elevated, [
          ['/bin/sh', '-c', LinuxMitmTrustStore.removeScript, 'flclash'],
        ]);
      });

      test('asks for no elevation for a CA the bundle does not hold', () async {
        expect(await store().remove(_ca), isTrue);

        expect(elevated, isEmpty);
      });

      test('reports a declined elevation', () async {
        files[LinuxMitmTrustStore.bundles.first] = _pem;
        elevation = false;

        expect(await store().remove(_ca), isFalse);
      });

      test('reports a database it could not clear', () async {
        await touch('/home/.pki/nssdb/cert9.db');
        listDatabases(stays: true);

        expect(await store().remove(_ca), isFalse);
      });

      test('reports databases no certutil can reach', () async {
        await touch('/home/.pki/nssdb/cert9.db');

        expect(await store(certutil: false).remove(_ca), isFalse);
      });
    });

    test('a CA in the system bundle and every browser is trusted', () async {
      files[LinuxMitmTrustStore.bundles.first] = 'other\n$_pem';
      await touch('/home/.pki/nssdb/cert9.db');
      processes.stub('${root.path}/bin/certutil', stdout: _pem);

      final check = await store().check(_ca, issueLeaf);

      expect(check.trust, MitmTrust.ready);
      expect(check.missingStores, isEmpty);
      expect(processes.argumentsOf('${root.path}/bin/certutil').single, [
        '-d',
        'sql:${database('/.pki/nssdb')}',
        '-L',
        '-n',
        LinuxMitmTrustStore.nickname,
        '-a',
      ]);
    });

    test('a browser without the CA leaves it partly trusted', () async {
      files[LinuxMitmTrustStore.bundles.last] = _pem;
      final profiles = database('/.mozilla/firefox');
      directories[profiles] = ['$profiles/abc.default-release'];
      await touch('/home/.mozilla/firefox/abc.default-release/cert9.db');
      processes.stub('${root.path}/bin/certutil', exitCode: 255);

      final check = await store().check(_ca, issueLeaf);

      expect(check.trust, MitmTrust.untrusted);
      expect(check.missingStores, ['Firefox (abc.default-release)']);
      expect(check.certutilInstall, isNull);
    });

    test('no store with the CA means it is not installed', () async {
      await touch('/home/.pki/nssdb/cert9.db');

      final check = await store(certutil: false).check(_ca, issueLeaf);

      expect(check.trust, MitmTrust.notInstalled);
      expect(check.certutilInstall, isNotNull);
    });

    test('the system bundle alone is enough without a browser', () async {
      files[LinuxMitmTrustStore.bundles[2]] = _pem;

      final check = await store(certutil: false).check(_ca, issueLeaf);

      expect(check.trust, MitmTrust.ready);
      expect(check.certutilInstall, isNull);
    });

    test('installing elevates once and replaces the browser copies', () async {
      await touch('/home/.pki/nssdb/cert9.db');

      expect(await store().install(_ca), MitmInstallOutcome.installed);

      final pemPath = '${root.path}/temp-0.pem';
      expect(elevated, [
        [
          '/bin/sh',
          '-c',
          LinuxMitmTrustStore.installScript,
          'flclash',
          pemPath,
        ],
      ]);
      final db = 'sql:${database('/.pki/nssdb')}';
      expect(processes.argumentsOf('${root.path}/bin/certutil'), [
        ['-d', db, '-D', '-n', LinuxMitmTrustStore.nickname],
        [
          '-d',
          db,
          '-A',
          '-t',
          'C,,',
          '-n',
          LinuxMitmTrustStore.nickname,
          '-i',
          pemPath,
        ],
      ]);
    });

    test('a declined elevation adds nothing to the browsers', () async {
      await touch('/home/.pki/nssdb/cert9.db');
      elevation = false;

      await expectLater(store().install(_ca), throwsA(anything));
      expect(processes.runs, isEmpty);
    });
  });
}
