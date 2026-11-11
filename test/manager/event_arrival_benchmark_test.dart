@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingListener with CoreEventListener {
  @override
  final bool wantsRequestEvents = true;
  @override
  final bool wantsDnsEvents = true;
  final List<Log> logs = [];
  final List<TrackerInfo> requests = [];
  final List<DnsQuery> dnsQueries = [];

  @override
  void onLog(Log log) => logs.add(log);

  @override
  void onRequest(TrackerInfo connection) => requests.add(connection);

  @override
  void onDns(DnsQuery dnsQuery) => dnsQueries.add(dnsQuery);
}

void main() {
  test('event arrival', () {
    final listener = _RecordingListener();
    coreEventManager.addListener(listener);
    addTearDown(() => coreEventManager.removeListener(listener));

    final now = DateTime.now().microsecondsSinceEpoch;
    void emitBatch() {
      for (var i = 0; i < 400; i++) {
        coreEventManager.sendEvent(
          CoreEvent(
            type: CoreEventType.log,
            data: {'LogLevel': 'info', 'Payload': 'bench', 'dateTime': now},
          ),
        );
      }
      for (var i = 0; i < 120; i++) {
        coreEventManager.sendEvent(
          CoreEvent(
            type: CoreEventType.request,
            data: {
              'id': 'c-$i',
              'metadata': const {'network': 'tcp'},
              'upload': 0,
              'download': 0,
              'start': now,
              'chains': const <String>[],
              'rule': 'MATCH',
              'rulePayload': '',
            },
          ),
        );
      }
      for (var i = 0; i < 240; i++) {
        coreEventManager.sendEvent(
          CoreEvent(
            type: CoreEventType.dns,
            data: {'domain': 'example$i.test', 'type': 'A', 'time': now},
          ),
        );
      }
    }

    void timed(String name, void Function() run) {
      for (var warmup = 0; warmup < 5; warmup++) {
        run();
      }
      final runs = <int>[];
      for (var attempt = 0; attempt < 9; attempt++) {
        final sw = Stopwatch()..start();
        run();
        sw.stop();
        runs.add(sw.elapsedMicroseconds);
      }
      runs.sort();
      stdout.writeln('$name: ${runs[4]}us (min ${runs.first})');
    }

    emitBatch();
    timed('sendEvent x760', emitBatch);
    stdout.writeln(
      'models built: ${listener.logs.length + listener.requests.length + listener.dnsQueries.length}',
    );
  });

  test('timestamp construction', () {
    final text = DateTime.now().toIso8601String();
    final millis = DateTime.now().millisecondsSinceEpoch;
    final micros = DateTime.now().microsecondsSinceEpoch;

    void timed(String name, void Function() run) {
      for (var warmup = 0; warmup < 5; warmup++) {
        run();
      }
      final runs = <int>[];
      for (var attempt = 0; attempt < 9; attempt++) {
        final sw = Stopwatch()..start();
        run();
        sw.stop();
        runs.add(sw.elapsedMicroseconds);
      }
      runs.sort();
      stdout.writeln('$name: ${runs[4]}us (min ${runs.first})');
    }

    timed('fromMillisecondsSinceEpochUtc x10000', () {
      for (var i = 0; i < 10000; i++) {
        DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
      }
    });
    timed('fromMicrosecondsSinceEpochUtc x10000', () {
      for (var i = 0; i < 10000; i++) {
        DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
      }
    });
    timed('parse x10000', () {
      for (var i = 0; i < 10000; i++) {
        DateTime.parse(text);
      }
    });
    timed('fromMillisecondsSinceEpoch x10000', () {
      for (var i = 0; i < 10000; i++) {
        DateTime.fromMillisecondsSinceEpoch(millis);
      }
    });
    timed('fromMicrosecondsSinceEpoch x10000', () {
      for (var i = 0; i < 10000; i++) {
        DateTime.fromMicrosecondsSinceEpoch(micros);
      }
    });
  });
}
