@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('filters first-seen DNS queries within the budget', () {
    const attempts = 30;
    const count = 3000;
    final batches = List.generate(attempts, (attempt) {
      return List.generate(count, (index) {
        return DnsQuery(
          domain: 'domain-$attempt-$index.test',
          type: 'A',
          answers: const ['1.1.1.1'],
          time: DateTime.utc(2026),
        );
      });
    });

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final state = DnsQueriesState(dnsQueries: batches[attempt]);
      expect(state.copyWith(query: 'zzz-$attempt').list, isEmpty);
    }
    stopwatch.stop();

    stdout.writeln(
      'dnsQueryColdSearch attempts=$attempts rows=$count '
      'totalUs=${stopwatch.elapsedMicroseconds}',
    );
  });
}
