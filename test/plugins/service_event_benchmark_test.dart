@Skip('Manual performance benchmark')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingListener with ServiceListener {
  var events = 0;

  @override
  void onServiceEvent(CoreEvent event) {
    events++;
  }
}

const _channelName = '$packageName/service';
const _channel = MethodChannel(_channelName);
const _codec = StandardMethodCodec();

Future<void> _emitBatch(List<Map<String, Object?>> batch) {
  final payload = json.encode(
    CoreMethodCall(method: CoreMethod.message, arguments: batch).toJson(),
  );
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channelName,
        _codec.encodeMethodCall(MethodCall('event', utf8.encode(payload))),
        null,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Install the real service handler before the mock, like the plugin tests.
  Service();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('android core event batches stay within the budget', () async {
    const batchSize = 300;
    const repetitions = 200;
    const warmups = 5;
    final batch = List<Map<String, Object?>>.generate(batchSize, (index) {
      return {
        'type': index.isEven ? 'log' : 'loaded',
        'data': index.isEven
            ? {'LogLevel': 'info', 'Payload': 'event-$index'}
            : 'provider-$index',
      };
    });

    final listener = _CountingListener();
    Service().addListener(listener);
    addTearDown(() => Service().removeListener(listener));

    for (var i = 0; i < warmups; i++) {
      await _emitBatch(batch);
    }

    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < repetitions; i++) {
      await _emitBatch(batch);
    }
    stopwatch.stop();

    stdout.writeln(
      'androidServiceEvent batchSize=$batchSize repetitions=$repetitions '
      'received=${listener.events} '
      'perBatchUs=${stopwatch.elapsedMicroseconds / repetitions}',
    );
    expect(listener.events, (repetitions + warmups) * batchSize);
  });
}
