import 'package:fl_clash/features/connection/tracker_speed_ranker.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo _tracker(
  String id, {
  int upload = 0,
  int download = 0,
  DateTime? start,
}) {
  return TrackerInfo(
    id: id,
    upload: upload,
    download: download,
    start: start ?? DateTime.utc(2026),
    metadata: const Metadata(),
    chains: const [],
    rule: 'MATCH',
    rulePayload: '',
  );
}

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);
  DateTime at(double seconds) =>
      t0.add(Duration(milliseconds: (seconds * 1000).round()));
  List<String> ids(List<TrackerInfo> trackerInfos) =>
      trackerInfos.map((trackerInfo) => trackerInfo.id).toList();

  test('reports no speed on the first sample and ranks by traffic', () {
    final ranked = TrackerSpeedRanker().rank([
      _tracker('a', download: 100),
      _tracker('b', download: 900),
    ], t0);

    expect(ids(ranked), ['b', 'a']);
    expect(ranked.map((trackerInfo) => trackerInfo.downloadSpeed), [0, 0]);
  });

  test('reuses rows when the derived speed does not change', () {
    final ranker = TrackerSpeedRanker();
    final first = ranker.rank([_tracker('a', download: 100)], t0);
    final second = ranker.rank(first, t0);

    expect(identical(second.single, first.single), isTrue);
  });

  test('derives speed from the delta over the elapsed time', () {
    final ranker = TrackerSpeedRanker();
    ranker.rank([_tracker('a', upload: 100, download: 1000)], t0);

    final ranked = ranker.rank([
      _tracker('a', upload: 1100, download: 5000),
    ], at(2));

    expect(ranked.single.uploadSpeed, 500);
    expect(ranked.single.downloadSpeed, 2000);
  });

  test('puts an active connection above a larger idle one', () {
    final ranker = TrackerSpeedRanker();
    ranker.rank([_tracker('idle', download: 1 << 30), _tracker('active')], t0);

    final ranked = ranker.rank([
      _tracker('idle', download: 1 << 30),
      _tracker('active', download: 4096),
    ], at(1));

    expect(ids(ranked), ['active', 'idle']);
  });

  test('keeps the order of connections with similar speeds', () {
    final ranker = TrackerSpeedRanker();
    ranker.rank([_tracker('a'), _tracker('b')], t0);
    final first = ranker.rank([
      _tracker('a', download: 5000),
      _tracker('b', download: 4500),
    ], at(1));
    expect(ids(first), ['a', 'b']);

    final second = ranker.rank([
      _tracker('a', download: 10000),
      _tracker('b', download: 10200),
    ], at(2));

    expect(ids(second), ['a', 'b']);
    expect(second.last.downloadSpeed, greaterThan(second.first.downloadSpeed!));
  });

  test('ignores a sample taken too soon after the previous one', () {
    final ranker = TrackerSpeedRanker();
    ranker.rank([_tracker('a')], t0);
    ranker.rank([_tracker('a', download: 1000)], at(1));

    final ranked = ranker.rank([_tracker('a', download: 1100)], at(1.05));

    expect(ranked.single.downloadSpeed, 1000);
  });

  test('a connection that comes back starts over', () {
    final ranker = TrackerSpeedRanker();
    ranker.rank([_tracker('a', upload: 100, download: 1000)], t0);
    expect(
      ranker
          .rank([_tracker('a', upload: 1100, download: 5000)], at(2))
          .single
          .uploadSpeed,
      500,
    );

    // Absent for a poll, its counters moved on without it: a delta measured
    // across the gap would read as a spike on a connection that only changed
    // network.
    ranker.rank([_tracker('b')], at(3));
    final back = ranker.rank([_tracker('a', upload: 1101)], at(4));
    expect(back.single.uploadSpeed, 0);
    expect(back.single.downloadSpeed, 0);
  });

  test('connections that never come back are not carried into the order', () {
    final ranker = TrackerSpeedRanker();
    final live = [_tracker('live-a', download: 10), _tracker('live-b')];
    final first = ranker.rank(live, t0);

    // More unique connections than the state map holds for absent ones, so
    // the rows that left are dropped while these keep their published slots.
    for (var index = 0; index < 3000; index++) {
      ranker.rank([_tracker('transient-$index', upload: index)], t0);
    }
    final again = ranker.rank(live, t0);
    expect(ids(again), ['live-a', 'live-b']);
    expect(again.first.downloadSpeed, first.first.downloadSpeed);
    expect(again.last.downloadSpeed, first.last.downloadSpeed);
  });

  test('hands back an unchanged connection as the same instance', () {
    final ranker = TrackerSpeedRanker();
    ranker.rank([_tracker('idle'), _tracker('active')], t0);
    final first = ranker.rank([
      _tracker('idle'),
      _tracker('active', download: 1000),
    ], at(1));

    final second = ranker.rank([
      _tracker('idle'),
      _tracker('active', download: 3000),
    ], at(2));

    TrackerInfo byId(List<TrackerInfo> ranked, String id) =>
        ranked.firstWhere((trackerInfo) => trackerInfo.id == id);
    expect(byId(second, 'idle'), same(byId(first, 'idle')));
    expect(byId(second, 'active'), isNot(same(byId(first, 'active'))));
    expect(byId(second, 'active').downloadSpeed, 2000);
  });

  test('answers a settled poll with the order it published', () {
    final ranker = TrackerSpeedRanker();
    final rows = [
      for (var index = 0; index < 200; index++)
        _tracker('node-$index', download: index * 137),
    ];

    final first = ranker.rank(rows, t0);
    final second = ranker.rank(rows, t0);
    final third = ranker.rank(rows, t0);

    expect(
      ids(second),
      ids(first),
      reason: 'a poll that moved nothing keeps the order',
    );
    expect(ids(third), ids(first));
    for (var index = 0; index < rows.length; index++) {
      expect(
        identical(third[index], first[index]),
        isTrue,
        reason: 'a settled poll answers with the rows it published',
      );
    }
  });

  test('reorders when the connection that led goes quiet', () {
    final ranker = TrackerSpeedRanker();
    final leading = _tracker('leading', download: 10000);
    final trailing = _tracker('trailing', download: 20000);

    final first = ranker.rank([leading, trailing], t0);
    expect(ids(first), [
      'trailing',
      'leading',
    ], reason: 'neither sends, so the larger total leads');

    final sending = ranker.rank([
      leading.copyWith(download: 11000),
      trailing.copyWith(download: 20000),
    ], at(1));
    expect(ids(sending), [
      'leading',
      'trailing',
    ], reason: 'the row that gained traffic leads while it sends');

    // It stops. Speed halves with every poll, so a row stays active for a few
    // before it is idle again, and the order it published while it sent does
    // not describe the table by then.
    var readAt = at(1);
    var quiet = sending;
    for (var poll = 0; poll < 12; poll++) {
      readAt = readAt.add(const Duration(seconds: 1));
      quiet = ranker.rank([
        leading.copyWith(download: 11000),
        trailing.copyWith(download: 20000),
      ], readAt);
    }
    expect(
      ids(quiet),
      ids(first),
      reason: 'the quiet leader falls behind the row that always carried more',
    );
  });
}
