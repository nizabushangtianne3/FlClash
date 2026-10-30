import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo _tracker(
  String id, {
  int upload = 0,
  int download = 0,
  String host = 'example.com',
}) {
  return TrackerInfo(
    id: id,
    upload: upload,
    download: download,
    start: DateTime.utc(2026),
    metadata: Metadata(host: host),
    chains: const ['DIRECT'],
    rule: 'MATCH',
    rulePayload: '',
  );
}

Future<void> seedConnections(
  Connections notifier,
  ConnectionDelta delta,
) async {
  notifier.useReader(({resync = false}) async => delta);
  await notifier.refresh();
}

void main() {
  test('folds a connection delta into the existing table', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(connectionsProvider.notifier);
    await seedConnections(
      notifier,
      ConnectionDelta(
        added: [_tracker('connection-1'), _tracker('connection-2')],
        count: 2,
      ),
    );

    notifier.useReader(
      ({resync = false}) async => ConnectionDelta(
        removed: const ['connection-1'],
        added: [_tracker('connection-3', download: 7)],
        count: 2,
      ),
    );
    await notifier.refresh();

    final snapshot = container.read(connectionsProvider);
    expect(snapshot.count, 2);
    expect(snapshot.connections.map((row) => row.id), [
      'connection-2',
      'connection-3',
    ]);
    expect(snapshot.connections.last.download, 7);
  });

  test('an unchanged connection delta keeps revision and rows', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(connectionsProvider.notifier);
    await seedConnections(
      notifier,
      ConnectionDelta(added: [_tracker('connection-1')], count: 1),
    );
    final before = container.read(connectionsProvider);

    notifier.useReader(
      ({resync = false}) async => const ConnectionDelta(count: 1),
    );
    await notifier.refresh();

    final after = container.read(connectionsProvider);
    expect(identical(after, before), isTrue);
    expect(after.revision, before.revision);
  });

  test('a repolled connection with the same identity and traffic is equal', () {
    final first = ConnectionsSnapshot(
      count: 1,
      connections: [_tracker('connection-1', host: 'example.com')],
    );
    final second = ConnectionsSnapshot(
      count: 1,
      connections: [_tracker('connection-1', host: 'example.org')],
    );

    expect(first == second, isTrue);
  });

  test('changed traffic makes a connection snapshot unequal', () {
    final first = ConnectionsSnapshot(connections: [_tracker('connection-1')]);
    final second = ConnectionsSnapshot(
      connections: [_tracker('connection-1', download: 1)],
    );

    expect(first == second, isFalse);
  });

  test('a different connection identity makes a snapshot unequal', () {
    final first = ConnectionsSnapshot(connections: [_tracker('connection-1')]);
    final second = ConnectionsSnapshot(connections: [_tracker('connection-2')]);

    expect(first == second, isFalse);
  });
}
