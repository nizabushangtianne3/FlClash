import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef ProcessLivenessProbe = Future<bool> Function(int pid);

/// A recycled pid reads as alive, which delays a confirmation but never fakes one.
Future<bool> isProcessAlive(int pid) async {
  if (pid <= 0) {
    return false;
  }
  if (Platform.isWindows) {
    return _isWindowsProcessAlive(pid);
  }
  if (Platform.isLinux) {
    return _isLinuxProcessAlive(pid);
  }
  final result = await Process.run('ps', ['-o', 'stat=', '-p', '$pid']);
  final state = (result.stdout as String).trim();
  return result.exitCode == 0 && state.isNotEmpty && !state.startsWith('Z');
}

Future<bool> _isLinuxProcessAlive(int pid) async {
  final String stat;
  try {
    stat = await File('/proc/$pid/stat').readAsString();
  } on FileSystemException {
    return false;
  }
  final state = stat.substring(stat.lastIndexOf(')') + 1).trim();
  return state.isNotEmpty && state[0] != 'Z' && state[0] != 'X';
}

const _processQueryLimitedInformation = 0x1000;
const _errorInvalidParameter = 87;
const _stillActive = 259;

typedef _OpenProcessNative = Pointer<Void> Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = Pointer<Void> Function(int, int, int);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
typedef _GetExitCodeProcessNative =
    Int32 Function(Pointer<Void>, Pointer<Uint32>);
typedef _GetExitCodeProcessDart = int Function(Pointer<Void>, Pointer<Uint32>);
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandleDart = int Function(Pointer<Void>);

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _openProcess = _kernel32
    .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
final _getLastError = _kernel32
    .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
final _getExitCodeProcess = _kernel32
    .lookupFunction<_GetExitCodeProcessNative, _GetExitCodeProcessDart>(
      'GetExitCodeProcess',
    );
final _closeHandle = _kernel32
    .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

// A Helper-spawned Core belongs to SYSTEM; OpenProcess fails with
// ERROR_INVALID_PARAMETER only when no such process exists.
bool _isWindowsProcessAlive(int pid) {
  final handle = _openProcess(_processQueryLimitedInformation, 0, pid);
  if (handle == nullptr) {
    return _getLastError() != _errorInvalidParameter;
  }
  final exitCode = calloc<Uint32>();
  try {
    if (_getExitCodeProcess(handle, exitCode) == 0) {
      return true;
    }
    return exitCode.value == _stillActive;
  } finally {
    calloc.free(exitCode);
    _closeHandle(handle);
  }
}
