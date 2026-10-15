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

  final _samples = <String, _SpeedSample>{};
  var _positions = const <String, int>{};

  List<TrackerInfo> rank(List<TrackerInfo> trackerInfos, DateTime now) {
    if (trackerInfos.isEmpty) {
      _samples.clear();
      _positions = const {};
      return trackerInfos;
    }
    final samples = {
      for (final trackerInfo in trackerInfos)
        trackerInfo.id: _sample(trackerInfo, now),
    };
    _samples.removeWhere((id, _) => !samples.containsKey(id));
    for (final entry in samples.entries) {
      _samples[entry.key] = entry.value;
    }

    TrackerInfo withSpeed(TrackerInfo trackerInfo) {
      final sample = samples[trackerInfo.id]!;
      if (trackerInfo.uploadSpeed == sample.uploadSpeed &&
          trackerInfo.downloadSpeed == sample.downloadSpeed) {
        return trackerInfo;
      }
      return trackerInfo.copyWith(
        uploadSpeed: sample.uploadSpeed,
        downloadSpeed: sample.downloadSpeed,
      );
    }

    // All idle: sort by traffic once, then keep the resulting order stable.
    var anyActive = false;
    for (final sample in samples.values) {
      if (sample.rankSpeed >= 1) {
        anyActive = true;
        break;
      }
    }
    if (!anyActive) {
      final ranked =
          [for (final trackerInfo in trackerInfos) withSpeed(trackerInfo)]
            ..sort((a, b) {
              final traffic = (b.upload + b.download).compareTo(
                a.upload + a.download,
              );
              if (traffic != 0) {
                return traffic;
              }
              final start = b.start.compareTo(a.start);
              return start != 0 ? start : a.id.compareTo(b.id);
            });
      _positions = {
        for (final (index, trackerInfo) in ranked.indexed)
          trackerInfo.id: index,
      };
      return ranked;
    }

    final buckets = {
      for (final trackerInfo in trackerInfos)
        trackerInfo.id: samples[trackerInfo.id]!.rankSpeed < 1
            ? 0
            : (log(samples[trackerInfo.id]!.rankSpeed) / ln2).floor() + 1,
    };
    final trafficBy = {
      for (final trackerInfo in trackerInfos)
        trackerInfo.id: trackerInfo.upload + trackerInfo.download,
    };

    final ranked =
        [for (final trackerInfo in trackerInfos) withSpeed(trackerInfo)]
          ..sort((a, b) {
            final bucketA = buckets[a.id]!;
            final bucket = buckets[b.id]!.compareTo(bucketA);
            if (bucket != 0) {
              return bucket;
            }
            if (bucketA > 0) {
              final position = (_positions[a.id] ?? trackerInfos.length)
                  .compareTo(_positions[b.id] ?? trackerInfos.length);
              if (position != 0) {
                return position;
              }
            }
            final traffic = trafficBy[b.id]!.compareTo(trafficBy[a.id]!);
            if (traffic != 0) {
              return traffic;
            }
            final start = b.start.compareTo(a.start);
            return start != 0 ? start : a.id.compareTo(b.id);
          });
    _positions = {
      for (final (index, trackerInfo) in ranked.indexed) trackerInfo.id: index,
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
