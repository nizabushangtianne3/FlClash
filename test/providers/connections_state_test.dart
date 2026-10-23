import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/state.dart';
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

void main() {
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
