@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo _request(int index, {String rule = 'DOMAIN-SUFFIX'}) {
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
    rule: rule,
    rulePayload: 'example-$index.com',
  );
}

void main() {
  test('offering a facet whose values are all distinct within the budget', () {
    const count = 500;
    const attempts = 2000;
    final items = [
      for (var index = 0; index < count; index++)
        _request(index, rule: 'DOMAIN-SUFFIX-$index'),
    ];
    final ruleFacet = trackerInfoFacets.firstWhere(
      (facet) => facet.kind == RecordFacetKind.rule,
    );

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      ruleFacet.optionsOf(items);
    }
    stopwatch.stop();
    final perOfferUs = stopwatch.elapsedMicroseconds / attempts;
    stdout.writeln(
      'recordFacetOfferDistinct rows=$count attempts=$attempts '
      'perOfferUs=$perOfferUs',
    );
  });

  test('offering the request facets within the budget', () {
    const count = 500;
    const attempts = 2000;
    final items = [for (var index = 0; index < count; index++) _request(index)];
    final offered = trackerInfoFacets.where((facet) => facet.offered).toList();

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
