@Skip('Manual performance benchmark')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/spill.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _groups = 200;
const _members = 20;
const _nodes = 1000;

String _groupName(int index) => 'group-${index.toString().padLeft(3, '0')}';
String _memberName(int index) => 'member-${index.toString().padLeft(3, '0')}';
String _nodeName(int index) => 'node-${index.toString().padLeft(4, '0')}';

/// The frame `core/proxy.go` answers `getProxies` with: one cached document
/// per group, one per node, names interleaved, over the response envelope.
Map<String, Object?> _proxiesAnswer() {
  final proxies = <String, Object?>{};
  for (var g = 0; g < _groups; g++) {
    proxies[_groupName(g)] = {
      'type': 'Selector',
      'name': _groupName(g),
      'now': _memberName(0),
      'all': [for (var m = 0; m < _members; m++) _memberName(m)],
      'testUrl': '',
      'hidden': false,
      'icon': '',
      'emptyFallback': 'COMPATIBLE',
    };
  }
  for (var n = 0; n < _nodes; n++) {
    proxies[_nodeName(n)] = {'name': _nodeName(n), 'type': 'Direct'};
  }
  return {
    'id': '1',
    'result': {
      'proxies': proxies,
      'all': [for (var g = 0; g < _groups; g++) _groupName(g)],
    },
  };
}

/// The frame `core/connection.go` answers a 500-row resync with: one row
/// document per tracker over the delta envelope.
Map<String, Object?> _connectionsAnswer({int rows = 500}) {
  TrackerInfo row(int index) {
    final start = DateTime.utc(2026);
    return TrackerInfo(
      id: 'connection-$index',
      upload: index,
      download: index * 3,
      start: start.add(Duration(milliseconds: index)),
      metadata: const Metadata(network: 'tcp', host: 'example.com'),
      chains: const ['DIRECT'],
      rule: 'MATCH',
      rulePayload: '',
    );
  }

  return {
    'id': '2',
    'result': {
      'added': [for (var i = 0; i < rows; i++) row(i).toJson()],
      'removed': <String>[],
      'count': rows,
    },
  };
}

Future<void> _measure(String label, int rounds, Future<void> Function() body) async {
  await body();
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < rounds; i++) {
    await body();
  }
  stopwatch.stop();
  stdout.writeln('$label ${stopwatch.elapsedMicroseconds ~/ rounds}us');
}

void main() {
  test('measures the getProxies and getConnections receive paths', () async {
    final proxiesFrame = utf8.encode(json.encode(_proxiesAnswer()));
    stdout.writeln(
      'groups.receive frameBytes=${proxiesFrame.length} '
      'groups=$_groups members=$_members nodes=$_nodes',
    );
    const proxiesState = ComputeGroupsState(
      proxiesData: ProxiesData(proxies: {}, all: []),
      sortType: ProxiesSortType.none,
      delayMap: {},
      selectedMap: {},
      defaultTestUrl: '',
    );

    await _measure('proxies.frameDecodeUs', 50, () async {
      final decoded = utf8.decoder.fuse(json.decoder).convert(proxiesFrame);
      CoreMethodResponse.fromJson(Map<String, Object?>.from(decoded as Map));
    });
    await _measure('proxies.buildGroupsOnUiUs', 50, () async {
      final decoded = utf8.decoder.fuse(json.decoder).convert(proxiesFrame);
      final response = CoreMethodResponse.fromJson(
        Map<String, Object?>.from(decoded as Map),
      );
      final data = ProxiesData.fromJson(
        Map<String, dynamic>.from(response.result as Map),
      );
      final built = await buildGroups(
        proxiesState.copyWith(proxiesData: data),
      );
      if (built.length != _groups) throw StateError('built ${built.length}');
    });
    await _measure('proxies.toGroupsTaskUs', 50, () async {
      final decoded = utf8.decoder.fuse(json.decoder).convert(proxiesFrame);
      final response = CoreMethodResponse.fromJson(
        Map<String, Object?>.from(decoded as Map),
      );
      final data = ProxiesData.fromJson(
        Map<String, dynamic>.from(response.result as Map),
      );
      final built = await toGroupsTask(proxiesState.copyWith(proxiesData: data));
      if (built.length != _groups) throw StateError('built ${built.length}');
    });

    final connectionsFrame = utf8.encode(json.encode(_connectionsAnswer()));
    stdout.writeln('connections.receive frameBytes=${connectionsFrame.length}');
    await _measure('connections.frameDecodeAndModelUs', 50, () async {
      final decoded = utf8.decoder.fuse(json.decoder).convert(connectionsFrame);
      withResultModel(
        CoreMethod.getConnections,
        Map<String, Object?>.from(decoded as Map),
      );
    });
  });
}
