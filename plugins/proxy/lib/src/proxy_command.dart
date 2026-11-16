import 'dart:io';

import 'package:flutter/foundation.dart';

const proxyHost = '127.0.0.1';

/// Whether a loopback port still has a listener. A failed probe counts as one.
abstract interface class ProxyPortProbe {
  Future<bool> isListening(int port);
}

class SocketPortProbe implements ProxyPortProbe {
  const SocketPortProbe();

  @override
  Future<bool> isListening(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress(proxyHost, type: InternetAddressType.IPv4),
        port,
        timeout: const Duration(milliseconds: 200),
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } on Object {
      return true;
    }
  }
}

typedef ProxyProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      bool runInShell,
    });

typedef ProxyExecutableChecker = Future<bool> Function(String executable);

@immutable
class ProxyCommand {
  final String executable;
  final List<String> args;
  final bool runInShell;
  final bool optional;

  ProxyCommand(
    this.executable,
    List<String> args, {
    this.runInShell = false,
    this.optional = false,
  }) : args = List.unmodifiable(args);
}

class ProxyCommandRunner {
  final ProxyProcessRunner _processRunner;

  ProxyCommandRunner(this._processRunner);

  Future<ProcessResult> process(
    String executable,
    List<String> arguments, {
    bool runInShell = false,
  }) {
    return _processRunner(executable, arguments, runInShell: runInShell);
  }

  Future<bool> run(Iterable<ProxyCommand> commands) async {
    var executed = false;
    for (final command in commands) {
      executed = true;
      if (!await _succeeds(command) && !command.optional) {
        return false;
      }
    }
    return executed;
  }

  Future<bool> _succeeds(ProxyCommand command) async {
    try {
      final result = await process(
        command.executable,
        command.args,
        runInShell: command.runInShell,
      );
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}
