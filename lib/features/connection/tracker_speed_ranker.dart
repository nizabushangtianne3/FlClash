import 'dart:math';

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

  var _samples = <String, _SpeedSample>{};
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
    _samples = {
      for (var index = 0; index < count; index++)
        trackerInfos[index].id: samples[index],
    };

    // All idle: sort by traffic once, then keep the resulting order stable.
    var anyActive = false;
    for (final sample in samples) {
      if (sample.rankSpeed >= 1) {
        anyActive = true;
        break;
      }
    }
    final traffic = [
      for (final trackerInfo in trackerInfos)
        trackerInfo.upload + trackerInfo.download,
    ];
    final order = List<int>.generate(count, (index) => index);
    if (!anyActive) {
      order.sort((a, b) {
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
    } else {
      final buckets = [
        for (final sample in samples)
          sample.rankSpeed < 1 ? 0 : (log(sample.rankSpeed) / ln2).floor() + 1,
      ];
      final positions = _positions;
      order.sort((a, b) {
        final bucket = buckets[b].compareTo(buckets[a]);
        if (bucket != 0) {
          return bucket;
        }
        if (buckets[a] > 0) {
          final position = (positions[trackerInfos[a].id] ?? count).compareTo(
            positions[trackerInfos[b].id] ?? count,
          );
          if (position != 0) {
            return position;
          }
        }
        final trafficCompare = traffic[b].compareTo(traffic[a]);
        if (trafficCompare != 0) {
          return trafficCompare;
        }
        final start = trackerInfos[b].start.compareTo(trackerInfos[a].start);
        return start != 0
            ? start
            : trackerInfos[a].id.compareTo(trackerInfos[b].id);
      });
    }

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
