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
  static final int _minSampleGapMicros = _minSampleGap.inMicroseconds;
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

  /// The order the last published poll answered, as source indices, and the
  /// stamp of the poll that produced it. A table whose rows, buckets and idle
  /// order all still stand answers with it again, which is what keeps a steady
  /// poll off the whole ordering pass.
  Int32List _publishedOrder = Int32List(0);
  int _publishedStamp = 0;

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
    final settled = _settledOrder(count, stamp, states, buckets, trackerInfos);
    if (settled != null) {
      order = settled;
    } else if (!anyActive) {
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
        // The walk leaves the idle rows in the order they were published last
        // poll, and an idle row's traffic does not move: one pass confirms that
        // is still the order the comparator would give, and the sort is the
        // expensive part of a poll over a table that is mostly idle.
        if (!_trafficOrdered(idle, traffic, trackerInfos)) {
          idle.sort((a, b) {
            final trafficCompare = traffic[b].compareTo(traffic[a]);
            if (trafficCompare != 0) {
              return trafficCompare;
            }
            final start = trackerInfos[b].start.compareTo(
              trackerInfos[a].start,
            );
            if (start != 0) {
              return start;
            }
            return trackerInfos[a].id.compareTo(trackerInfos[b].id);
          });
        }
        for (final index in idle) {
          ranked[cursor++] = index;
        }
      }
      order = ranked;
    }

    final published = _publish(trackerInfos, states, order);
    if (settled == null) {
      if (_publishedOrder.length != count) {
        _publishedOrder = Int32List(count);
      }
      for (var index = 0; index < count; index++) {
        _publishedOrder[index] = order[index];
      }
    }
    _publishedStamp = stamp;
    if (_rows.length > count + _purgeSlack) {
      _rows.removeWhere((_, row) => row.stamp != stamp);
    }
    return published;
  }

  /// The order the previous poll published, when it still answers this one: the
  /// rows are the ones it was built from, a row's bucket only ever moves it
  /// later in the order, and the pair of idle rows stands in the order its
  /// traffic gives. The whole ordering pass then has nothing to decide.
  Int32List? _settledOrder(
    int count,
    int stamp,
    List<_RowState> states,
    Int32List buckets,
    List<TrackerInfo> trackerInfos,
  ) {
    if (_publishedStamp != stamp - 1 || _publishedOrder.length != count) {
      return null;
    }
    final published = _publishedOrder;
    if (states[published[0]].stamp != stamp) {
      return null;
    }
    var previous = published[0];
    var previousBucket = buckets[previous];
    for (var index = 1; index < count; index++) {
      final source = published[index];
      if (states[source].stamp != stamp) {
        return null;
      }
      final bucket = buckets[source];
      if (bucket > previousBucket) {
        return null;
      }
      if (bucket == 0 &&
          previousBucket == 0 &&
          !_precedes(trackerInfos[previous], trackerInfos[source])) {
        return null;
      }
      previous = source;
      previousBucket = bucket;
    }
    return published;
  }

  /// Whether [first] stands where the ranking puts it ahead of [second] when
  /// neither carries traffic: more total traffic, then an earlier start, then
  /// the id.
  bool _precedes(TrackerInfo first, TrackerInfo second) {
    final firstTraffic = first.upload + first.download;
    final secondTraffic = second.upload + second.download;
    if (firstTraffic != secondTraffic) {
      return firstTraffic > secondTraffic;
    }
    final start = first.start.compareTo(second.start);
    if (start != 0) {
      return start > 0;
    }
    return first.id.compareTo(second.id) <= 0;
  }

  /// Whether the rows already stand in the order the comparator gives:
  /// traffic first, then an earlier start, then the id.
  bool _trafficOrdered(
    List<int> rows,
    Int64List traffic,
    List<TrackerInfo> trackerInfos,
  ) {
    for (var index = 1; index < rows.length; index++) {
      final previous = rows[index - 1];
      final current = rows[index];
      final trafficCompare = traffic[current].compareTo(traffic[previous]);
      if (trafficCompare > 0) {
        return false;
      }
      if (trafficCompare < 0) {
        continue;
      }
      final start = trackerInfos[current].start.compareTo(
        trackerInfos[previous].start,
      );
      if (start > 0) {
        return false;
      }
      if (start < 0) {
        continue;
      }
      if (trackerInfos[previous].id.compareTo(trackerInfos[current].id) > 0) {
        return false;
      }
    }
    return true;
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
    // A difference in microseconds rather than a Duration: one is arithmetic,
    // the other allocates for every row of every poll.
    final elapsed =
        now.microsecondsSinceEpoch - existing.at.microsecondsSinceEpoch;
    if (elapsed < _minSampleGapMicros) {
      existing.stamp = stamp;
      return existing;
    }
    final seconds = elapsed / Duration.microsecondsPerSecond;
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
