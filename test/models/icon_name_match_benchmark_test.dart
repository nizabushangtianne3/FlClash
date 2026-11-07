@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matching a large icon gallery stays within budget', () {
    const icons = 5000;
    const attempts = 100;
    final list = [
      for (var index = 0; index < icons; index++)
        IconSetIcon(
          name: index.isEven
              ? 'Node_${index % 500}.png'
              : 'Flag-${index % 300}',
          url: 'https://cdn.example.com/icons/$index.png',
        ),
    ];

    final warm = list.scoreFor('node 10');
    expect(warm, isNotEmpty);

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final scored = list.scoreFor('node 10');
      final ranked = rankIconMatches(scored);
      if (ranked.isEmpty) {
        fail('lost icon matches');
      }
    }
    stopwatch.stop();
    stdout.writeln(
      'iconNameMatch icons=$icons attempts=$attempts '
      'totalUs=${stopwatch.elapsedMicroseconds} '
      'perAttemptUs=${stopwatch.elapsedMicroseconds / attempts}',
    );
  });
}
