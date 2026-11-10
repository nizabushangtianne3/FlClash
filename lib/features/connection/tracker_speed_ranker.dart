import 'dart:math';
import 'dart:typed_data';

import 'package:fl_clash/models/models.dart';

/// What a poll keeps for one connection: the cumulative counters its last
/// sample was taken against, the speeds derived from them, the row it
/// published and the slot that row holds.
class _RowState {
  _RowState(this.upload, this.download, this.at, this.position);

  int stamp = 0;
  int upload;
  int download;
  DateTime at;
  int uploadSpeed = 0;
  int downloadSpeed = 0;
  double rankSpeed = 0;

  /// The slot this row held in the last published order. A connection the poll
  /// has never published is treated as arriving after the ones holding a slot.
  int position;
  TrackerInfo? output;
}

/// Derives per-connection speed from successive cumulative snapshots and
/// orders connections by it without reshuffling the list every poll.
class TrackerSpeedRanker {
  // Closing a connection triggers an out-of-band refresh; a delta over a few
  // milliseconds would read as a spike, so such samples keep the last speed.
  static const _minSampleGap = Duration(milliseconds: 500);
  static const _smoothing = 0.5;

  /// One map keyed by connection id carries what three per-poll maps used to:
  /// rebuilding a samples map, an outputs map and a positions map on every
  /// poll cost tens of thousands of string-keyed operations at ten thousand
  /// connections, which is where the poll spent most of its time.
  final _rows = <String, _RowState>{};

  /// A poll stamp. A row whose stamp is not the previous poll's was absent
  /// then, so it starts over instead of deriving a speed from counters that
  /// moved on without it: this is what clearing the sample map every poll
  /// meant.
  int _stamp = 0;

  // Rows that never came back are dropped once they outnumber the live ones
  // by this much. A drop walks the map without hashing any key, so the walk
  // stays amortized against the joins that filled the map.
  static const _purgeSlack = 1024;

  static final _vacant = _RowState(
    0,
    0,
    DateTime.fromMillisecondsSinceEpoch(0),
    0,
  );

  List<TrackerInfo> rank(List<TrackerInfo> trackerInfos, DateTime now) {
    if (trackerInfos.isEmpty) {
      _rows.clear();
      return trackerInfos;
    }
    final count = trackerInfos.length;
    final stamp = ++_stamp;
    final previousStamp = stamp - 1;
    final states = List<_RowState>.filled(count, _vacant);

    // All idle: sort by traffic once, then keep the resulting order stable.
    var anyActive = false;
    final traffic = Int64List(count);
    final positions = Int32List(count);
    final buckets = Int32List(count);
    for (var index = 0; index < count; index++) {
      final trackerInfo = trackerInfos[index];
      final row = _sample(trackerInfo, now, stamp, previousStamp, count);
      states[index] = row;
      traffic[index] = trackerInfo.upload + trackerInfo.download;
      positions[index] = row.position;
      buckets[index] = row.rankSpeed < 1
          ? 0
          : (log(row.rankSpeed) / ln2).floor() + 1;
      if (row.rankSpeed >= 1) {
        anyActive = true;
      }
    }

    final Int32List order;
    if (!anyActive) {
      order = Int32List.fromList(
        List<int>.generate(count, (index) => index)..sort((a, b) {
          final trafficCompare = traffic[b].compareTo(traffic[a]);
          if (trafficCompare != 0) {
            return trafficCompare;
          }
          final start = trackerInfos[b].start.compareTo(trackerInfos[a].start);
          if (start != 0) {
            return start;
          }
          return trackerInfos[a].id.compareTo(trackerInfos[b].id);
        }),
      );
    } else {
      var maxBucket = 0;
      for (var index = 0; index < count; index++) {
        if (buckets[index] > maxBucket) {
          maxBucket = buckets[index];
        }
      }

      // Counting-sort current rows by their previous rank. Rows are unique in
      // the common case; only equal positions (mostly new rows) need the
      // exact traffic/start/id tie-break.
      // The counting sort writes every slot exactly once, so the order needs
      // no sentinel fill.
      final positionCounts = Int32List(count + 1);
      for (var index = 0; index < count; index++) {
        positionCounts[positions[index]]++;
      }
      final positionStarts = Int32List(count + 3);
      for (var position = 0; position <= count; position++) {
        positionStarts[position + 1] =
            positionStarts[position] + positionCounts[position];
      }
      final positionOrder = Int32List(count);
      final positionCursors = Int32List(count + 1);
      for (var index = 0; index < count; index++) {
        final position = positions[index];
        positionOrder[positionStarts[position] + positionCursors[position]++] =
            index;
      }
      for (var position = 0; position <= count; position++) {
        final start = positionStarts[position];
        final end = start + positionCounts[position];
        if (end - start < 2) {
          continue;
        }
        final collision = positionOrder.sublist(start, end)
          ..sort((a, b) {
            final trafficCompare = traffic[b].compareTo(traffic[a]);
            if (trafficCompare != 0) {
              return trafficCompare;
            }
            final startCompare = trackerInfos[b].start.compareTo(
              trackerInfos[a].start,
            );
            return startCompare != 0
                ? startCompare
                : trackerInfos[a].id.compareTo(trackerInfos[b].id);
          });
        for (var index = 0; index < collision.length; index++) {
          positionOrder[start + index] = collision[index];
        }
      }

      final bucketHeads = Int32List(maxBucket + 1);
      final bucketTails = Int32List(maxBucket + 1);
      final nextIndices = Int32List(count);
      for (var index = 0; index < maxBucket + 1; index++) {
        bucketHeads[index] = -1;
      }
      for (var index = 0; index < count; index++) {
        nextIndices[index] = -1;
      }
      for (final index in positionOrder) {
        final bucket = buckets[index];
        if (bucketHeads[bucket] < 0) {
          bucketHeads[bucket] = index;
        } else {
          nextIndices[bucketTails[bucket]] = index;
        }
        bucketTails[bucket] = index;
      }

      final ranked = Int32List(count);
      var cursor = 0;
      // Every row lands in exactly one bucket, so this too is written in full.
      for (var bucket = maxBucket; bucket >= 0; bucket--) {
        var source = bucketHeads[bucket];
        if (source < 0) {
          continue;
        }
        if (bucket > 0) {
          while (source >= 0) {
            ranked[cursor++] = source;
            source = nextIndices[source];
          }
          continue;
        }
        final idle = List<int>.generate(count - cursor, (index) => index);
        var idleCursor = 0;
        while (source >= 0) {
          idle[idleCursor++] = source;
          source = nextIndices[source];
        }
        idle.sort((a, b) {
          final trafficCompare = traffic[b].compareTo(traffic[a]);
          if (trafficCompare != 0) {
            return trafficCompare;
          }
          final start = trackerInfos[b].start.compareTo(trackerInfos[a].start);
          if (start != 0) {
            return start;
          }
          return trackerInfos[a].id.compareTo(trackerInfos[b].id);
        });
        for (final index in idle) {
          ranked[cursor++] = index;
        }
      }
      order = ranked;
    }

    final published = _publish(trackerInfos, states, order);
    if (_rows.length > count + _purgeSlack) {
      _rows.removeWhere((_, row) => row.stamp != stamp);
    }
    return published;
  }

  /// Answers the order as rows, reusing the published instance of a row whose
  /// derived speeds did not move so the list below diffing sees it as the same
  /// row, and records the slot each published row holds for the next poll.
  List<TrackerInfo> _publish(
    List<TrackerInfo> trackerInfos,
    List<_RowState> states,
    List<int> order,
  ) {
    final count = states.length;
    final ranked = List<TrackerInfo>.generate(count, (index) {
      final source = order[index];
      final row = states[source];
      final trackerInfo = row.output ?? trackerInfos[source];
      if (trackerInfo.uploadSpeed == row.uploadSpeed &&
          trackerInfo.downloadSpeed == row.downloadSpeed) {
        row.output = trackerInfo;
        return trackerInfo;
      }
      final next = trackerInfo.copyWith(
        uploadSpeed: row.uploadSpeed,
        downloadSpeed: row.downloadSpeed,
      );
      row.output = next;
      return next;
    });
    for (var index = 0; index < count; index++) {
      states[order[index]].position = index;
    }
    return ranked;
  }

  _RowState _sample(
    TrackerInfo trackerInfo,
    DateTime now,
    int stamp,
    int previousStamp,
    int count,
  ) {
    final id = trackerInfo.id;
    final existing = _rows[id];
    if (existing == null || existing.stamp != previousStamp) {
      final row = _RowState(
        trackerInfo.upload,
        trackerInfo.download,
        now,
        count,
      );
      row.stamp = stamp;
      _rows[id] = row;
      return row;
    }
    final elapsed = now.difference(existing.at);
    if (elapsed < _minSampleGap) {
      existing.stamp = stamp;
      return existing;
    }
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final uploadSpeed = max(0, trackerInfo.upload - existing.upload) / seconds;
    final downloadSpeed =
        max(0, trackerInfo.download - existing.download) / seconds;
    final rankSpeed =
        existing.rankSpeed +
        (uploadSpeed + downloadSpeed - existing.rankSpeed) * _smoothing;
    existing.upload = trackerInfo.upload;
    existing.download = trackerInfo.download;
    existing.at = now;
    existing.uploadSpeed = uploadSpeed.round();
    existing.downloadSpeed = downloadSpeed.round();
    existing.rankSpeed = rankSpeed < 1 ? 0 : rankSpeed;
    existing.stamp = stamp;
    return existing;
  }
}
