import 'dart:math';
import 'dart:typed_data';

import 'package:fl_clash/models/models.dart';

class _SpeedSample {
  final int upload;
  final int download;
  final DateTime at;
  final int uploadSpeed;
  final int downloadSpeed;
  final double rankSpeed;

  const _SpeedSample({
    required this.upload,
    required this.download,
    required this.at,
    required this.uploadSpeed,
    required this.downloadSpeed,
    required this.rankSpeed,
  });
}

/// Derives per-connection speed from successive cumulative snapshots and
/// orders connections by it without reshuffling the list every poll.
class TrackerSpeedRanker {
  // Closing a connection triggers an out-of-band refresh; a delta over a few
  // milliseconds would read as a spike, so such samples keep the last speed.
  static const _minSampleGap = Duration(milliseconds: 500);
  static const _smoothing = 0.5;

  final _samples = <String, _SpeedSample>{};
  var _positions = const <String, int>{};

  List<TrackerInfo> rank(List<TrackerInfo> trackerInfos, DateTime now) {
    if (trackerInfos.isEmpty) {
      _samples.clear();
      _positions = const {};
      return trackerInfos;
    }
    final count = trackerInfos.length;
    final samples = List<_SpeedSample>.generate(
      count,
      (index) => _sample(trackerInfos[index], now),
    );
    final sampleMap = _samples..clear();
    for (var index = 0; index < count; index++) {
      sampleMap[trackerInfos[index].id] = samples[index];
    }

    // All idle: sort by traffic once, then keep the resulting order stable.
    var anyActive = false;
    final traffic = Int64List(count);
    final positions = Int64List(count);
    for (var index = 0; index < count; index++) {
      final trackerInfo = trackerInfos[index];
      final sample = samples[index];
      traffic[index] = trackerInfo.upload + trackerInfo.download;
      positions[index] = _positions[trackerInfo.id] ?? count;
      if (sample.rankSpeed >= 1) {
        anyActive = true;
      }
    }
    if (!anyActive) {
      final order = List<int>.generate(count, (index) => index)
        ..sort((a, b) {
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
      return _ranked(trackerInfos, samples, order, count);
    }

    final buckets = Int64List(count);
    var maxBucket = 0;
    for (var index = 0; index < count; index++) {
      final rankSpeed = samples[index].rankSpeed;
      buckets[index] = rankSpeed < 1 ? 0 : (log(rankSpeed) / ln2).floor() + 1;
      if (buckets[index] > maxBucket) {
        maxBucket = buckets[index];
      }
    }

    // Counting-sort current rows by their previous rank. Rows are unique in the
    // common case; only equal positions (mostly new rows) need the exact
    // traffic/start/id tie-break.
    final positionCounts = Int64List(count + 1);
    for (var index = 0; index < count; index++) {
      positionCounts[positions[index]]++;
    }
    final positionStarts = Int64List(count + 3);
    for (var position = 0; position <= count; position++) {
      positionStarts[position + 1] =
          positionStarts[position] + positionCounts[position];
    }
    final positionOrder = List<int>.filled(count, -1, growable: false);
    final positionCursors = Int64List(count + 1);
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

    final bucketHeads = Int64List(maxBucket + 1);
    final bucketTails = Int64List(maxBucket + 1);
    final nextIndices = Int64List(count);
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

    final order = List<int>.filled(count, -1, growable: false);
    var cursor = 0;
    for (var bucket = maxBucket; bucket >= 0; bucket--) {
      var source = bucketHeads[bucket];
      if (source < 0) {
        continue;
      }
      if (bucket > 0) {
        while (source >= 0) {
          order[cursor++] = source;
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
        order[cursor++] = index;
      }
    }

    return _ranked(trackerInfos, samples, order, count);
  }

  List<TrackerInfo> _ranked(
    List<TrackerInfo> trackerInfos,
    List<_SpeedSample> samples,
    List<int> order,
    int count,
  ) {
    final ranked = List<TrackerInfo>.generate(count, (index) {
      final source = order[index];
      final trackerInfo = trackerInfos[source];
      final sample = samples[source];
      if (trackerInfo.uploadSpeed == sample.uploadSpeed &&
          trackerInfo.downloadSpeed == sample.downloadSpeed) {
        return trackerInfo;
      }
      return trackerInfo.copyWith(
        uploadSpeed: sample.uploadSpeed,
        downloadSpeed: sample.downloadSpeed,
      );
    });
    _positions = {
      for (var index = 0; index < count; index++) ranked[index].id: index,
    };
    return ranked;
  }

  _SpeedSample _sample(TrackerInfo trackerInfo, DateTime now) {
    final previous = _samples[trackerInfo.id];
    if (previous == null) {
      return _SpeedSample(
        upload: trackerInfo.upload,
        download: trackerInfo.download,
        at: now,
        uploadSpeed: 0,
        downloadSpeed: 0,
        rankSpeed: 0,
      );
    }
    final elapsed = now.difference(previous.at);
    if (elapsed < _minSampleGap) {
      return previous;
    }
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final uploadSpeed = max(0, trackerInfo.upload - previous.upload) / seconds;
    final downloadSpeed =
        max(0, trackerInfo.download - previous.download) / seconds;
    final rankSpeed =
        previous.rankSpeed +
        (uploadSpeed + downloadSpeed - previous.rankSpeed) * _smoothing;
    return _SpeedSample(
      upload: trackerInfo.upload,
      download: trackerInfo.download,
      at: now,
      uploadSpeed: uploadSpeed.round(),
      downloadSpeed: downloadSpeed.round(),
      rankSpeed: rankSpeed < 1 ? 0 : rankSpeed,
    );
  }
}
