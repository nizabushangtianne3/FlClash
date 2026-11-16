import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show ProxyState;
import 'package:proxy/proxy.dart';

final proxy = system.isDesktop && !safeModeBuild ? Proxy() : null;

final systemProxyQueue = proxy == null ? null : SystemProxyQueue(proxy!);

/// Clears a system proxy a killed run left behind.
class StaleProxyCleaner {
  final Proxy _proxy;

  StaleProxyCleaner(this._proxy);

  Future<void> clean() async {
    try {
      final cleared = await _proxy.clearStaleProxy();
      if (cleared) {
        commonPrint.log('cleared a system proxy left behind by a killed run');
      }
    } catch (error) {
      commonPrint.log(
        'unable to clear a stale system proxy: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
    }
  }
}

final staleProxyCleaner = proxy == null ? null : StaleProxyCleaner(proxy!);

/// Exit's stop goes through the same queue as every other change, so a start
/// still waiting behind a slow call cannot turn the proxy back on after it.
/// A stop also clears settings someone else made, so it only undoes a start
/// of this run.
class SystemProxyQueue {
  final Proxy _proxy;
  Future<void> _tail = Future.value();
  bool _closed = false;
  bool _applied = false;

  SystemProxyQueue(this._proxy);

  Future<void> apply(ProxyState state) {
    return _enqueue(() async {
      if (_closed) {
        return;
      }
      if (state.isStart && state.systemProxy) {
        _applied = true;
        if (!await _proxy.startProxy(state.port, state.bassDomain)) {
          _logFailure();
        }
      } else {
        await _stop();
      }
    });
  }

  Future<void> close() {
    _closed = true;
    return _enqueue(_stop);
  }

  Future<void> _stop() async {
    if (!_applied) {
      return;
    }
    if (!await _proxy.stopProxy()) {
      _logFailure();
      return;
    }
    _applied = false;
  }

  void _logFailure() {
    commonPrint.log('update system proxy failed', logLevel: LogLevel.warning);
  }

  Future<void> _enqueue(Future<void> Function() task) {
    return _tail = _tail.then((_) => task()).catchError((Object error) {
      commonPrint.log(
        'update system proxy failed: $error',
        logLevel: LogLevel.warning,
      );
    });
  }
}

String proxyEnvCommand(int port, {required bool isWindows}) {
  final url = 'http://127.0.0.1:$port';
  return isWindows ? 'set \$env:all_proxy=$url' : 'export all_proxy=$url';
}
