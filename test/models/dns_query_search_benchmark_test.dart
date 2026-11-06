@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('filters ten thousand DNS queries within the budget', () {
    const count = 10000;
    const attempts = 50;
    final queries = [
      for (var index = 0; index < count; index++)
        DnsQuery(
          domain: 'domain-$index.test',
          type: 'A',
          answers: const ['1.1.1.1'],
          time: DateTime.utc(2026),
        ),
    ];
    final base = DnsQueriesState(dnsQueries: queries);
    final warm = base.copyWith(query: 'zzz');
    expect(warm.list, isEmpty);

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final state = base.copyWith(query: 'zzz$attempt');
      expect(state.list, isEmpty);
    }
    stopwatch.stop();

    stdout.writeln(
      'dnsQuerySearch count=$count attempts=$attempts '
      'totalUs=${stopwatch.elapsedMicroseconds}',
    );
  });
}
