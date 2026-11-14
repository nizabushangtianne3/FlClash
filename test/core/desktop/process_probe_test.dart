import 'dart:io';

import 'package:fl_clash/core/desktop/process_probe.dart';
import 'package:flutter_test/flutter_test.dart';

// The kernel keeps a dying process in its table for a moment after the
// runtime reports the exit, so a probe that lands in that window still
// reads the pid as alive. Polling until the kernel drops it keeps the
// assertion on the outcome instead of on how fast the host retires it.
Future<bool> _probeUntilExited(int pid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (!await isProcessAlive(pid)) {
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return true;
}

void main() {
  test('the current process is alive', () async {
    expect(await isProcessAlive(pid), isTrue);
  });

  test('an exited child process is not alive', () async {
    final process = await Process.start(
      Platform.isWindows ? 'ping' : 'sleep',
      Platform.isWindows ? ['-n', '2', '127.0.0.1'] : ['2'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    process.kill();
    await process.exitCode;

    expect(await _probeUntilExited(process.pid), isFalse);
  });

  test('non-positive pids are never alive', () async {
    expect(await isProcessAlive(0), isFalse);
    expect(await isProcessAlive(-1), isFalse);
  });
}
