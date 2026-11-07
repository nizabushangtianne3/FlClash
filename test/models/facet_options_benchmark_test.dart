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
      network: index.isEven ? 'tcp' : 'udp',
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
  test('offering the request facets within the budget', () {
    const count = 500;
    const attempts = 2000;
    final items = [
      for (var index = 0; index < count; index++) _request(index),
    ];
    final offered = trackerInfoFacets
        .where((facet) => facet.offered)
        .toList();

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final facet in offered) {
        facet.optionsOf(items);
      }
    }
    stopwatch.stop();
    final perOfferUs = stopwatch.elapsedMicroseconds / attempts;
    stdout.writeln(
      'recordFacetOffer rows=$count attempts=$attempts '
      'perOfferUs=$perOfferUs',
    );
  });
}
