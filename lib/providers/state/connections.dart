part of '../state.dart';

@immutable
class ConnectionsSnapshot {
  const ConnectionsSnapshot({this.count = 0, this.connections = const []});

  final int count;
  final List<TrackerInfo> connections;

  ConnectionsSnapshot copyWith({int? count, List<TrackerInfo>? connections}) {
    return ConnectionsSnapshot(
      count: count ?? this.count,
      connections: connections ?? this.connections,
    );
  }

  /// A Core connection ID identifies its immutable descriptive fields; polling
  /// only moves the traffic counters, so equality stays off the deep model.
  @override
  bool operator ==(Object other) =>
      other is ConnectionsSnapshot &&
      other.count == count &&
      other.connections.length == connections.length &&
      _sameConnections(other.connections);

  bool _sameConnections(List<TrackerInfo> other) {
    for (var index = 0; index < connections.length; index++) {
      final current = connections[index];
      final next = other[index];
      if (identical(current, next)) {
        continue;
      }
      if (current.id != next.id ||
          current.upload != next.upload ||
          current.download != next.download ||
          current.start != next.start) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(count, connections.length);
}

@Riverpod(keepAlive: true)
class Connections extends _$Connections {
  static const _countInterval = Duration(seconds: 3);
  static const _snapshotInterval = Duration(milliseconds: 2500);

  int _snapshotWatchers = 0;
  int _countWatchers = 0;
  bool _polling = false;
  Timer? _timer;
  Duration? _interval;
  Future<List<TrackerInfo>> Function()? _snapshotReader;
  Future<int> Function()? _countReader;

  @override
  ConnectionsSnapshot build() {
    ref.onDispose(_stopTimer);
    ref.listen(appVisibleProvider, (_, visible) {
      if (visible) {
        _syncTimer();
      } else {
        _stopTimer();
      }
    });
    return const ConnectionsSnapshot();
  }

  void attachCount(Future<int> Function()? reader) {
    if (reader != null) {
      _countReader = reader;
    }
    _countWatchers++;
    _syncTimer();
  }

  void detachCount() {
    if (_countWatchers == 0) {
      return;
    }
    _countWatchers--;
    if (_countWatchers == 0) {
      _countReader = null;
    }
    _syncTimer();
  }

  void attachSnapshot(Future<List<TrackerInfo>> Function()? reader) {
    if (reader != null) {
      _snapshotReader = reader;
    }
    _snapshotWatchers++;
    _syncTimer();
  }

  void detachSnapshot() {
    if (_snapshotWatchers == 0) {
      return;
    }
    _snapshotWatchers--;
    if (_snapshotWatchers == 0) {
      _snapshotReader = null;
    }
    _syncTimer();
  }

  Duration? get _nextInterval {
    if (_snapshotWatchers > 0) {
      return _snapshotInterval;
    }
    if (_countWatchers > 0) {
      return _countInterval;
    }
    return null;
  }

  void _syncTimer() {
    final interval = _nextInterval;
    if (interval == null || !ref.read(appVisibleProvider)) {
      _stopTimer();
      return;
    }
    if (_timer != null && _interval == interval) {
      return;
    }
    _stopTimer();
    _interval = interval;
    scheduleMicrotask(_poll);
    _timer = Timer.periodic(interval, (_) => unawaited(Future(_poll)));
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _interval = null;
  }

  Future<void> _poll() async {
    if (_polling) {
      return;
    }
    _polling = true;
    try {
      if (_snapshotWatchers > 0) {
        final connections =
            await (_snapshotReader ??
                ref.read(coreHandlerProvider).getConnections)();
        if (_canPublish) {
          state = ConnectionsSnapshot(
            count: connections.length,
            connections: connections,
          );
        }
        return;
      }
      if (_countWatchers == 0) {
        return;
      }
      if (_countReader == null &&
          ref.read(coreStatusProvider) != CoreStatus.connected) {
        state = const ConnectionsSnapshot();
        return;
      }
      final count =
          await (_countReader ??
              ref.read(coreHandlerProvider).getConnectionCount)();
      if (_canPublish) {
        state = state.copyWith(count: count);
      }
    } catch (error) {
      commonPrint.log(
        'updateConnections error: $error',
        logLevel: coreFailureLogLevel(error),
      );
    } finally {
      _polling = false;
    }
  }

  bool get _canPublish =>
      ref.mounted && _nextInterval != null && ref.read(appVisibleProvider);
}
