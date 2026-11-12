@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Log _log(int index) => Log(
  logLevel: LogLevel.values[index % 5],
  payload: '[TCP] connected to $index.example.com:${40000 + index}',
  dateTime: DateTime.utc(2026),
);

TrackerInfo _request(int index) => TrackerInfo(
  id: '$index',
  upload: index,
  download: index * 3,
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

List<String> _selectedValues(List<RecordFilter> filters, RecordFacetKind kind) {
  return [
    for (final filter in filters)
      if (filter.kind == kind) filter.value,
  ];
}

void main() {
  test('offering facets of a log table pays only for the values it reads', () {
    const count = 500;
    const attempts = 2000;
    final items = [for (var index = 0; index < count; index++) _log(index)];
    final controller = RecordFilterController<Log>(facets: logFacets)
      ..add(const RecordFilter(RecordFacetKind.level, 'info'));

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      controller.offer(items);
    }
    stopwatch.stop();
    final perOfferUs = stopwatch.elapsedMicroseconds / attempts;
    stdout.writeln(
      'recordOfferLogs rows=$count attempts=$attempts perOfferUs=$perOfferUs',
    );
    expect(perOfferUs, lessThan(1000));
  });

  test('offering facets of a request table with a filter held', () {
    const count = 500;
    const attempts = 2000;
    final items = [for (var index = 0; index < count; index++) _request(index)];
    final controller = RecordFilterController<TrackerInfo>(
      facets: trackerInfoFacets,
    )..add(const RecordFilter(RecordFacetKind.rule, 'DOMAIN-SUFFIX'));

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      controller.offer(items);
    }
    stopwatch.stop();
    final perOfferUs = stopwatch.elapsedMicroseconds / attempts;
    stdout.writeln(
      'recordOfferRequests rows=$count attempts=$attempts '
      'perOfferUs=$perOfferUs',
    );
    expect(perOfferUs, lessThan(1000));
  });

  test('building the selected list one offered facet pays for', () {
    const count = 500;
    const attempts = 2000;
    final items = [for (var index = 0; index < count; index++) _request(index)];
    final controller = RecordFilterController<TrackerInfo>(
      facets: trackerInfoFacets,
    )..add(const RecordFilter(RecordFacetKind.rule, 'DOMAIN-SUFFIX'));

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final facet in trackerInfoFacets.where((facet) => facet.offered)) {
        _selectedValues(controller.filters, facet.kind);
      }
    }
    stopwatch.stop();
    final perOfferUs = stopwatch.elapsedMicroseconds / attempts;
    stdout.writeln(
      'recordOfferSelected rows=$count attempts=$attempts '
      'perOfferUs=$perOfferUs',
    );
  });
}
