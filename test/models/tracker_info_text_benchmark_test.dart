@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo _request(int index) {
  return TrackerInfo(
    id: '$index',
    start: DateTime.utc(2026),
    metadata: Metadata(
      network: 'tcp',
      host: 'host-$index.test',
      process: 'com.android.chrome',
      uid: 10123,
    ),
    chains: const ['Proxy', 'DIRECT'],
    rule: 'DOMAIN-SUFFIX',
    rulePayload: 'example-$index.com',
  );
}

void main() {
  test('building the text a grouped table reads per row within the budget', () {
    const count = 500;
    const attempts = 2000;
    final items = [for (var index = 0; index < count; index++) _request(index)];

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final item in items) {
        item.ruleText;
      }
    }
    stopwatch.stop();
    final ruleUs = stopwatch.elapsedMicroseconds / attempts;

    stopwatch.reset();
    stopwatch.start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final item in items) {
        item.progressText;
      }
    }
    stopwatch.stop();
    final progressUs = stopwatch.elapsedMicroseconds / attempts;

    stdout.writeln(
      'trackerInfoText rows=$count attempts=$attempts '
      'ruleTextUs=$ruleUs progressTextUs=$progressUs',
    );
  });
}
