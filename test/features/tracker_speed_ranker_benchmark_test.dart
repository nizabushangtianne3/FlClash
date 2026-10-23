@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/features/connection/tracker_speed_ranker.dart';
import 'package:fl_clash/features/connection/tracker_info_list.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ranks ten thousand active connections within the budget', () {
    const count = 10000;
    const snapshots = 20;
    final start = DateTime.utc(2026);
    final inputs = [
      for (var snapshot = 0; snapshot < snapshots; snapshot++)
        [
          for (var index = 0; index < count; index++)
            TrackerInfo(
              id: 'connection-$index',
              upload: index + snapshot * 17,
              download: index * 31 + snapshot * 101,
              start: start.add(Duration(milliseconds: index)),
              metadata: const Metadata(),
              chains: const ['DIRECT'],
              rule: 'MATCH',
              rulePayload: '',
            ),
        ],
    ];
    final ranker = TrackerSpeedRanker();
    final stopwatch = Stopwatch()..start();
    for (var snapshot = 0; snapshot < snapshots; snapshot++) {
      ranker.rank(inputs[snapshot], start.add(Duration(seconds: snapshot)));
    }
    stopwatch.stop();
    final perSnapshot = stopwatch.elapsedMicroseconds ~/ snapshots;
    stdout.writeln(
      'ranker count=$count snapshots=$snapshots '
      'totalUs=${stopwatch.elapsedMicroseconds} perSnapshotUs=$perSnapshot',
    );
    expect(perSnapshot, lessThan(15000));
  });

  test('skips ten thousand unchanged rows within the budget', () {
    const count = 10000;
    const attempts = 20;

    List<TrackerInfo> rows() => [
      for (var index = 0; index < count; index++)
        TrackerInfo(
          id: 'connection-$index',
          upload: index,
          download: index * 31,
          start: DateTime.utc(2026).add(Duration(milliseconds: index)),
          metadata: const Metadata(),
          chains: const ['DIRECT'],
          rule: 'MATCH',
          rulePayload: '',
        ),
    ];

    final first = rows();
    final second = rows();
    final controller = TrackerInfoListController();
    addTearDown(controller.dispose);
    controller.setTrackerInfos(first);
    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      controller.setTrackerInfos(attempt.isEven ? second : first);
    }
    stopwatch.stop();
    final perAttempt = stopwatch.elapsedMicroseconds ~/ attempts;
    stdout.writeln(
      'unchanged rows count=$count attempts=$attempts '
      'totalUs=${stopwatch.elapsedMicroseconds} perAttemptUs=$perAttempt',
    );
    expect(perAttempt, lessThan(500));
  });
}
