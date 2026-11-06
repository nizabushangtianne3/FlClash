@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingListener with CoreEventListener {
  var logs = 0;
  var requests = 0;

  @override
  bool get wantsRequestEvents => true;

  @override
  void onLog(Log log) {
    logs++;
  }

  @override
  void onRequest(TrackerInfo connection) {
    requests++;
  }
}

void main() {
  test('dispatching core events stays within the budget', () {
    const count = 100000;
    final listener = _CountingListener();
    coreEventManager.addListener(listener);
    addTearDown(() => coreEventManager.removeListener(listener));

    for (var index = 0; index < 1000; index++) {
      coreEventManager.sendEvent(
        CoreEvent(
          type: CoreEventType.log,
          data: {
            'LogLevel': 'info',
            'Payload': 'warm-$index',
            'dateTime': '2026-11-07T00:00:00Z',
          },
        ),
      );
    }

    final stopwatch = Stopwatch()..start();
    for (var index = 0; index < count; index++) {
      coreEventManager.sendEvent(
        CoreEvent(
          type: CoreEventType.log,
          data: {
            'LogLevel': 'info',
            'Payload': 'log-$index',
            'dateTime': '2026-11-07T00:00:00Z',
          },
        ),
      );
    }
    stopwatch.stop();

    final logUs = stopwatch.elapsedMicroseconds / count;
    listener.logs = 0;
    stopwatch
      ..reset()
      ..start();
    for (var index = 0; index < count; index++) {
      coreEventManager.sendEvent(
        CoreEvent(
          type: CoreEventType.request,
          data: {
            'id': 'connection-$index',
            'metadata': {'network': 'tcp'},
            'upload': 0,
            'download': 0,
            'start': '2026-11-07T00:00:00Z',
            'chains': <String>[],
            'rule': 'MATCH',
            'rulePayload': '',
          },
        ),
      );
    }
    stopwatch.stop();

    final requestUs = stopwatch.elapsedMicroseconds / count;
    stdout.writeln(
      'coreEventDispatch count=$count logUs=$logUs requestUs=$requestUs',
    );
    expect(listener.logs, 0);
    expect(listener.requests, count);
  });
}
