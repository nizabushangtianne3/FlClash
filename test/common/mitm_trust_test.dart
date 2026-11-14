import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/mitm_trust.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

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

const _sha1 = '0D045E4AA451F22BE8D41A13A1F2E18446192632';
const _sha256 =
    '5684B99A4C8E9CB4F3639425A5D2B61C2D4B05C6531536268BAC4A2FD7378D17';

final _ca = MitmCertificate(
  pem: _pem,
  fingerprint:
      '56:84:B9:9A:4C:8E:9C:B4:F3:63:94:25:A5:D2:B6:1C:'
      '2D:4B:05:C6:53:15:36:26:8B:AC:4A:2F:D7:37:8D:17',
  subject: 'FlClash CA TEST0001',
  notBefore: DateTime.utc(2026, 10, 24),
  notAfter: DateTime.utc(2126, 9, 30),
);

class _MockApp extends Mock implements App {}

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

  test('the certificate is hashed from its DER', () {
    expect(mitmSha1Hex(_ca), _sha1);
    expect(mitmSha256Hex(_ca), _sha256);
  });

  group('Android', () {
    setUpAll(() => AppLocalizations.load(const Locale('en')));

    void locate(
      _MockApp app, {
      bool user = false,
      bool system = false,
      bool root = true,
    }) {
      when(
        () => app.locateCaCertificate(any()),
      ).thenAnswer((_) async => (user: user, system: system, root: root));
    }

    void stubUserInstall(_MockApp app, MitmInstallOutcome? outcome) {
      when(
        () => app.installCaCertificate(
          any(),
          name: any(named: 'name'),
          fileName: any(named: 'fileName'),
        ),
      ).thenAnswer((_) async => outcome);
    }

    test('an installer that does not open fails the install', () async {
      final app = _MockApp();
      locate(app, root: false);
      stubUserInstall(app, null);

      await expectLater(
        AndroidMitmTrustStore(app).install(_ca),
        throwsA(
          isA<MessageException>().having(
            (error) => error.message,
            'message',
            currentAppLocalizations.mitmSystemStoreFailed,
          ),
        ),
      );
    });

    test('a CA in the system store is trusted by every app', () async {
      final app = _MockApp();
      locate(app, system: true);

      final check = await AndroidMitmTrustStore(app).check(_ca, issueLeaf);

      expect(check.trust, MitmTrust.ready);
      expect(check.systemStore, isTrue);
      expect(check.rootAvailable, isTrue);
    });

    test('su installs the CA before the user store is offered', () async {
      final app = _MockApp();
      locate(app);
      when(
        () => app.installCaCertificateWithRoot(any()),
      ).thenAnswer((_) async => MitmInstallOutcome.installed);

      expect(
        await AndroidMitmTrustStore(app).install(_ca),
        MitmInstallOutcome.installed,
      );
      verifyNever(
        () => app.installCaCertificate(
          any(),
          name: any(named: 'name'),
          fileName: any(named: 'fileName'),
        ),
      );
    });

    test('a denied su falls back to the user store', () async {
      final app = _MockApp();
      locate(app);
      when(
        () => app.installCaCertificateWithRoot(any()),
      ).thenAnswer((_) async => null);
      stubUserInstall(app, MitmInstallOutcome.saved);

      expect(
        await AndroidMitmTrustStore(app).install(_ca),
        MitmInstallOutcome.saved,
      );
    });

    test('su takes the CA out of the system store', () async {
      final app = _MockApp();
      locate(app, system: true);
      when(
        () => app.removeCaCertificateWithRoot(any()),
      ).thenAnswer((_) async => true);

      expect(await AndroidMitmTrustStore(app).remove(_ca), isTrue);
      verify(() => app.removeCaCertificateWithRoot(any())).called(1);
    });

    test('a CA also in the user store is left for the user', () async {
      final app = _MockApp();
      locate(app, user: true, system: true);
      when(
        () => app.removeCaCertificateWithRoot(any()),
      ).thenAnswer((_) async => true);

      expect(await AndroidMitmTrustStore(app).remove(_ca), isFalse);
    });
  });

  group('macOS', () {
    MacOSMitmTrustStore store() => MacOSMitmTrustStore(
      home: '/Users/someone',
      run: processes.run,
      writeTemp: writeTemp,
    );

    test('a leaf that verifies for SSL means the CA is trusted', () async {
      final check = await store().check(_ca, issueLeaf);

      expect(check.trust, MitmTrust.ready);
      expect(written, ['leaf pem']);
      expect(processes.argumentsOf('/usr/bin/security').single, [
        'verify-cert',
        '-c',
        '${root.path}/temp-0.pem',
        '-p',
        'ssl',
        '-n',
        mitmCheckHost,
        '-L',
        '-q',
      ]);
    });

    test('a CA in the keychain that fails to verify is untrusted', () async {
      processes
        ..stub('/usr/bin/security verify-cert', exitCode: 1)
        ..stub(
          '/usr/bin/security find-certificate',
          stdout: 'SHA-256 hash: $_sha256\nSHA-1 hash: $_sha1\n',
        );

      final check = await store().check(_ca, issueLeaf);

      expect(check.trust, MitmTrust.untrusted);
      expect(processes.argumentsOf('/usr/bin/security').last, [
        'find-certificate',
        '-a',
        '-Z',
        '-c',
        _ca.subject,
      ]);
    });

    test('another CA by the same name is not this one', () async {
      processes
        ..stub('/usr/bin/security verify-cert', exitCode: 1)
        ..stub(
          '/usr/bin/security find-certificate',
          stdout: 'SHA-256 hash: ${'0' * 64}\n',
        );

      expect(
        (await store().check(_ca, issueLeaf)).trust,
        MitmTrust.notInstalled,
      );
    });

    test(
      'installing trusts the CA in the login keychain of the user',
      () async {
        expect(await store().install(_ca), MitmInstallOutcome.installed);

        expect(written, [_pem]);
        expect(processes.argumentsOf('/usr/bin/security').single, [
          'add-trusted-cert',
          '-r',
          'trustRoot',
          '-k',
          '/Users/someone/Library/Keychains/login.keychain-db',
          '${root.path}/temp-0.pem',
        ]);
        expect(File('${root.path}/temp-0.pem').existsSync(), isFalse);
      },
    );

    test('an install the user cancels throws', () async {
      processes.stub('/usr/bin/security add-trusted-cert', exitCode: 1);

      await expectLater(store().install(_ca), throwsA(isA<ProcessException>()));
    });

    test('removing deletes the CA by its hash', () async {
      expect(await store().remove(_ca), isTrue);

      expect(processes.argumentsOf('/usr/bin/security').single, [
        'delete-certificate',
        '-Z',
        _sha256,
        '-t',
        '/Users/someone/Library/Keychains/login.keychain-db',
      ]);
    });
  });

  group('Windows', () {
    WindowsMitmTrustStore store() =>
        WindowsMitmTrustStore(run: processes.run, writeTemp: writeTemp);

    test('installing adds the CA to the root store of the user', () async {
      expect(await store().install(_ca), MitmInstallOutcome.installed);

      expect(processes.argumentsOf('certutil').single, [
        '-addstore',
        '-user',
        'Root',
        '${root.path}/temp-0.pem',
      ]);
    });

    test('removing deletes the CA by its SHA-1', () async {
      expect(await store().remove(_ca), isTrue);

      expect(processes.argumentsOf('certutil').single, [
        '-user',
        '-delstore',
        'Root',
        _sha1,
      ]);
    });
  });
}
