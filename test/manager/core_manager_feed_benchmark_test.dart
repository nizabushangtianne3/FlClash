@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/manager/core_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_app.dart';

void main() {
  testWidgets('core feed flushes within the copy budget', (tester) async {
    final temp = Directory.systemTemp.createTempSync('core_feed_benchmark');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await useAppPaths(temp);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: HostApp(
          navigatorKey: globalState.navigatorKey,
          builder: (context, child) {
            globalState.measure = Measure.of(context, 1);
            return BannerHost(stacked: false, topInset: 0, child: child!);
          },
          home: const CoreManager(child: SizedBox()),
        ),
      ),
    );
    await tester.pump();

    const logs = 400;
    const requests = 120;
    const dnsQueries = 240;
    const traffic = 200;
    const flushes = 200;

    void emitBatch(int round) {
      for (var i = 0; i < logs; i++) {
        coreEventManager.sendEvent(
          CoreEvent(
            type: CoreEventType.log,
            data: {
              'LogLevel': 'info',
              'Payload': 'bench-$round-$i',
              'dateTime': DateTime.now().toIso8601String(),
            },
          ),
        );
      }
      for (var i = 0; i < requests; i++) {
        coreEventManager.sendEvent(
          CoreEvent(
            type: CoreEventType.request,
            data: {
              'id': 'c-$i',
              'metadata': {'network': 'tcp'},
              'upload': 0,
              'download': 0,
              'start': DateTime.now().toIso8601String(),
              'chains': <String>[],
              'rule': 'MATCH',
              'rulePayload': '',
            },
          ),
        );
      }
      for (var i = 0; i < dnsQueries; i++) {
        coreEventManager.sendEvent(
          CoreEvent(
            type: CoreEventType.dns,
            data: {
              'domain': 'example$i.test',
              'type': 'A',
              'time': DateTime.now().toIso8601String(),
            },
          ),
        );
      }
      coreEventManager.sendEvent(
        CoreEvent(
          type: CoreEventType.requestTraffic,
          data: [
            for (var i = 0; i < traffic; i++)
              {'id': 'c-$i', 'upload': 1, 'download': 2},
          ],
        ),
      );
    }

    for (var i = 0; i < 20; i++) {
      emitBatch(i);
      await tester.pump(renderThrottleDuration);
    }

    var elapsed = Duration.zero;
    for (var i = 0; i < flushes; i++) {
      emitBatch(i);
      final stopwatch = Stopwatch()..start();
      await tester.pump(renderThrottleDuration);
      stopwatch.stop();
      elapsed += stopwatch.elapsed;
    }

    final perFlushUs = elapsed.inMicroseconds / flushes;
    final perEventNs =
        elapsed.inMicroseconds *
        1000 /
        (flushes * (logs + requests + dnsQueries + traffic));
    stdout.writeln(
      'coreManagerFeedFlush flushes=$flushes items=$logs+$requests+$dnsQueries+$traffic '
      'perFlushUs=${perFlushUs.toStringAsFixed(2)} '
      'perEventNs=${perEventNs.toStringAsFixed(1)}',
    );
  });
}
