import 'package:fl_clash/common/proxy.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxyManager extends ConsumerStatefulWidget {
  final Widget child;

  const ProxyManager({super.key, required this.child});

  @override
  ConsumerState createState() => _ProxyManagerState();
}

class _ProxyManagerState extends ConsumerState<ProxyManager> {
  Future<void>? _activeUpdate;
  ProxyState? _pendingState;

  Future<void> _updateProxy(ProxyState proxyState) async {
    final isStart = proxyState.isStart;
    final systemProxy = proxyState.systemProxy;
    final port = proxyState.port;
    bool? result;
    if (isStart && systemProxy) {
      result = await proxy?.startProxy(port, proxyState.bassDomain);
    } else {
      result = await proxy?.stopProxy();
    }
    if (result == false) {
      commonPrint.log('update system proxy failed', logLevel: LogLevel.warning);
    }
  }

  void _scheduleUpdateProxy(ProxyState proxyState) {
    _pendingState = proxyState;
    _activeUpdate ??= _drainUpdates();
  }

  Future<void> _drainUpdates() async {
    try {
      while (true) {
        final state = _pendingState;
        if (state == null) {
          return;
        }
        _pendingState = null;
        try {
          await _updateProxy(state);
        } catch (error) {
          commonPrint.log(
            'update system proxy failed: $error',
            logLevel: LogLevel.warning,
          );
        }
      }
    } finally {
      _activeUpdate = null;
      final pending = _pendingState;
      if (pending != null) {
        _scheduleUpdateProxy(pending);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(proxyStateProvider, (prev, next) {
      if (prev != next) {
        _scheduleUpdateProxy(next);
      }
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
