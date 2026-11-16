import 'dart:io';

import 'proxy_command.dart';

class MacosProxy {
  final ProxyCommandRunner _commandRunner;
  final ProxyPortProbe _portProbe;

  MacosProxy({
    required ProxyCommandRunner commandRunner,
    ProxyPortProbe? portProbe,
  }) : _commandRunner = commandRunner,
       _portProbe = portProbe ?? const SocketPortProbe();

  Future<bool> start(int port, List<String> bypassDomain) async {
    final services = await _networkServices();
    return _commandRunner.run(
      services.expand(
        (service) => MacosProxyCommands.buildStart(service, port, bypassDomain),
      ),
    );
  }

  Future<bool> stop() async {
    final services = await _networkServices();
    return _commandRunner.run(services.expand(MacosProxyCommands.buildStop));
  }

  /// A run that was killed instead of exited leaves every network service
  /// pointing at a port nothing listens on. One that points elsewhere stays.
  Future<bool> clearStaleProxy() async {
    final services = await _networkServices();
    var cleared = false;
    for (final service in services) {
      final settings = await _commandRunner.process('/usr/sbin/networksetup', [
        '-getwebproxy',
        service,
      ]);
      if (settings.exitCode != 0) {
        continue;
      }
      final port = MacosProxyCommands.parseProxyPort(
        settings.stdout.toString(),
      );
      if (port == null || await _portProbe.isListening(port)) {
        continue;
      }
      final stopped = await _commandRunner.run(
        MacosProxyCommands.buildStop(service),
      );
      cleared = stopped || cleared;
    }
    return cleared;
  }

  Future<List<String>> _networkServices() async {
    try {
      final result = await _commandRunner.process('/usr/sbin/networksetup', [
        '-listallnetworkservices',
      ]);
      if (result.exitCode != 0) {
        return [];
      }
      return MacosProxyCommands.parseNetworkServices(result.stdout.toString());
    } on ProcessException {
      return [];
    }
  }
}

class MacosProxyCommands {
  /// The port of an enabled proxy that points at this app, or null.
  static int? parseProxyPort(String stdout) {
    final lines = stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    String? server;
    int? port;
    var enabled = false;
    for (final line in lines) {
      final separator = line.indexOf(':');
      if (separator < 0) {
        continue;
      }
      final key = line.substring(0, separator).trim().toLowerCase();
      final value = line.substring(separator + 1).trim();
      switch (key) {
        case 'enabled':
          enabled = value.toLowerCase() == 'yes';
        case 'server':
          server = value;
        case 'port':
          port = int.tryParse(value);
      }
    }
    if (!enabled || server != proxyHost || port == null) {
      return null;
    }
    if (port < 1 || port > 65535) {
      return null;
    }
    return port;
  }

  static List<ProxyCommand> buildStart(
    String service,
    int port,
    List<String> bypassDomain,
  ) {
    return [
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxy',
        service,
        proxyHost,
        '$port',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxy',
        service,
        proxyHost,
        '$port',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxy',
        service,
        proxyHost,
        '$port',
      ]),
      buildProxyBypass(service, bypassDomain),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxystate',
        service,
        'on',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxystate',
        service,
        'on',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxystate',
        service,
        'on',
      ]),
    ];
  }

  static List<ProxyCommand> buildStop(String service) {
    return [
      ProxyCommand('/usr/sbin/networksetup', [
        '-setautoproxystate',
        service,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxystate',
        service,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxystate',
        service,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxystate',
        service,
        'off',
      ]),
      buildProxyBypass(service, const []),
    ];
  }

  static ProxyCommand buildProxyBypass(
    String service,
    List<String> bypassDomain,
  ) {
    return ProxyCommand('/usr/sbin/networksetup', [
      '-setproxybypassdomains',
      service,
      if (bypassDomain.isEmpty) 'Empty' else ...bypassDomain,
    ]);
  }

  static List<String> parseNetworkServices(String stdout) {
    return stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where((line) => !line.startsWith('*'))
        .where((line) => !line.startsWith('An asterisk '))
        .toList();
  }
}
