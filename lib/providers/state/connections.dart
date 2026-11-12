part of '../state.dart';

@immutable
class ConnectionsSnapshot {
  const ConnectionsSnapshot({
    this.count = 0,
    this.connections = const [],
    this.revision = 0,
  });

  final int count;
  final List<TrackerInfo> connections;
  final int revision;

  ConnectionsSnapshot copyWith({int? count, List<TrackerInfo>? connections}) {
    return ConnectionsSnapshot(
      count: count ?? this.count,
      connections: connections ?? this.connections,
      revision: revision,
    );
  }

  /// Provider-produced snapshots carry a revision, so traffic updates can skip
  /// an O(n) comparison. Hand-built snapshots retain the old value equality.
  @override
  bool operator ==(Object other) {
    if (other is! ConnectionsSnapshot) return false;
    if (revision != 0 && other.revision != 0) {
      return revision == other.revision && other.count == count;
    }
    return other.count == count &&
        other.connections.length == connections.length &&
        _sameConnections(other.connections);
  }

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
  int get hashCode => revision == 0
      ? Object.hash(count, connections.length)
      : Object.hash(count, connections.length, revision);
}

@Riverpod(keepAlive: true)
class Connections extends _$Connections {
  /// A read that comes after a gap answers the whole table: what the Core did
  /// while nobody asked is unknown.
  static const _staleAfter = Duration(seconds: 5);

  bool _polling = false;
  bool _resync = true;
  DateTime? _lastRead;
  Map<String, TrackerInfo> _rows = {};
  List<TrackerInfo> _orderedRows = const [];
  Map<String, int> _slots = const {};
  Future<ConnectionDelta> Function({bool resync})? _reader;
  int _revision = 0;
  @override
  ConnectionsSnapshot build() {
    return const ConnectionsSnapshot();
  }

  void useReader(Future<ConnectionDelta> Function({bool resync})? reader) {
    _reader = reader;
  }

  /// Answers the Core and folds the answer into the table the app reads. A page
  /// polling faster than [staleAfter] is answered with what moved, so a page
  /// open over a busy Core stops paying for every row on every read.
  Future<void> refresh() {
    _resync =
        _resync ||
        _lastRead == null ||
        DateTime.now().difference(_lastRead!) > _staleAfter;
    return _read(resync: _resync);
  }

  /// The Core reports each connection's counters as they move, so the table
  /// does not wait for the next read to show them.
  void updateTraffic(Map<String, RequestTraffic> traffic) {
    if (traffic.isEmpty || !ref.mounted) {
      return;
    }
    // Both views of the table have to move together: [_rows] is what a keyed
    // lookup replaces, [_orderedRows] is what the app reads, and a map write
    // does not reach the list the snapshot publishes. The list is copied only
    // once a sample really moves a slot, so a table holding still is free.
    List<TrackerInfo>? orderedRows;
    for (final entry in traffic.entries) {
      final row = _rows[entry.key];
      if (row == null) {
        continue;
      }
      final upload = entry.value.upload;
      final download = entry.value.download;
      if (row.upload == upload && row.download == download) {
        continue;
      }
      final next = row.copyWith(upload: upload, download: download);
      _rows[entry.key] = next;
      final slot = _slots[entry.key];
      if (slot != null) {
        (orderedRows ??= List<TrackerInfo>.of(_orderedRows))[slot] = next;
      }
    }
    if (orderedRows == null) {
      return;
    }
    _orderedRows = orderedRows;
    state = ConnectionsSnapshot(
      count: _rows.length,
      connections: orderedRows,
      revision: ++_revision,
    );
  }

  Future<void> _read({required bool resync}) async {
    if (_polling) {
      return;
    }
    _polling = true;
    try {
      final reader = _reader ?? ref.read(coreHandlerProvider).getConnections;
      final delta = await reader(resync: resync);
      _lastRead = DateTime.now();
      _merge(delta, resync: resync);
    } catch (error) {
      commonPrint.log(
        'updateConnections error: $error',
        logLevel: coreFailureLogLevel(error),
      );
      // A table the Core no longer answers for is not worth keeping.
      _clear();
    } finally {
      _polling = false;
    }
  }

  void _merge(ConnectionDelta delta, {required bool resync}) {
    // A resync answers the whole table, so it replaces what the app holds
    // instead of folding into it.
    final rows = resync ? <String, TrackerInfo>{} : _rows;
    var changed = resync;
    for (final id in delta.removed) {
      if (rows.remove(id) != null) {
        changed = true;
      }
    }
    for (final row in delta.added) {
      rows[row.id] = row;
      changed = true;
    }
    // A table that no longer holds what the Core counts has missed an answer,
    // so the next read asks for the whole table again.
    _resync = rows.length != delta.count;
    if (!changed) {
      return;
    }
    _rows = rows;
    final orderedRows = rows.values.toList()
      ..sort((a, b) => b.start.compareTo(a.start));
    _orderedRows = orderedRows;
    _slots = {
      for (var index = 0; index < orderedRows.length; index++)
        orderedRows[index].id: index,
    };
    state = ConnectionsSnapshot(
      // The Core's own count leads: the table is what this app holds, and the
      // two disagree only until an answer it missed is asked for again.
      count: delta.count,
      connections: orderedRows,
      revision: ++_revision,
    );
  }

  void _clear() {
    if (_rows.isEmpty) {
      return;
    }
    _rows = {};
    _orderedRows = const [];
    _slots = const {};
    _resync = true;
    state = ConnectionsSnapshot(revision: ++_revision);
  }
}
