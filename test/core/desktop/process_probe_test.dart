import 'dart:io';

import 'package:fl_clash/core/desktop/process_probe.dart';
import 'package:flutter_test/flutter_test.dart';

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

    expect(await isProcessAlive(process.pid), isFalse);
  });

  test('non-positive pids are never alive', () async {
    expect(await isProcessAlive(0), isFalse);
    expect(await isProcessAlive(-1), isFalse);
  });
}
