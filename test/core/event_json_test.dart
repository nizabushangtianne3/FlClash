import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/core/event_json.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder with CoreEventListener {
  @override
  final bool wantsRequestEvents = true;
  @override
  final bool wantsDnsEvents = true;
  final logs = <(LogLevel, String)>[];
  final requests = <TrackerInfo>[];
  final dnsQueries = <DnsQuery>[];
  final traffic = <Map<String, RequestTraffic>>[];
  final loaded = <String>[];
  final crashes = <String>[];
  final dialerLoops = <String>[];
  final delays = <Delay>[];
  final geoUpdates = <GeoUpdatePayload>[];
  final routes = <RouteSnapshot>[];

  @override
  void onLog(Log log) => logs.add((log.logLevel, log.payload));
  @override
  void onRequest(TrackerInfo connection) => requests.add(connection);
  @override
  void onDns(DnsQuery dnsQuery) => dnsQueries.add(dnsQuery);
  @override
  void onRequestTraffic(Map<String, RequestTraffic> traffic) =>
      this.traffic.add(traffic);
  @override
  void onLoaded(String providerName) => loaded.add(providerName);
  @override
  void onCrash(String message) => crashes.add(message);
  @override
  void onDialerLoop(String proxyName) => dialerLoops.add(proxyName);
  @override
  void onDelay(Delay delay) => delays.add(delay);
  @override
  void onGeoUpdate(
    String geoType,
    bool updating,
    bool skipped,
    String? error,
  ) => geoUpdates.add(
    GeoUpdatePayload(
      geoType: geoType,
      updating: updating,
      skipped: skipped,
      error: error,
    ),
  );
  @override
  void onRouteChanged(RouteSnapshot snapshot) => routes.add(snapshot);
}

void main() {
  Uint8List bytesOf(Object? json) => utf8.encode(jsonEncode(json));

  Map<String, Object?> messageEnvelope(Object? arguments) =>
      CoreMethodCall(method: CoreMethod.message, arguments: arguments).toJson();

  _Recorder record(List<CoreEvent> events, {required bool batched}) {
    final recorder = _Recorder();
    coreEventManager.addListener(recorder);
    // Removed as soon as the pass is through: each comparison dispatches its
    // own batch and the earlier recorder must not see the later one.
    if (batched) {
      coreEventManager.sendEvents(events);
    } else {
      for (final event in events) {
        coreEventManager.sendEvent(event);
      }
    }
    coreEventManager.removeListener(recorder);
    return recorder;
  }

  /// The arguments list a frame carries, the way the transports read it.
  Object? argumentsOf(Uint8List frame) {
    final decoded = jsonDecode(utf8.decode(frame));
    return decoded is Map<String, Object?> ? decoded['arguments'] : null;
  }

  /// What the transports see for one frame: the fused reader first, the
  /// decoded path as its fallback and as the oracle.
  _Recorder effectiveEvents(Uint8List frame) {
    final fused = messageBatchFromFrame(frame);
    if (fused != null) {
      return record(fused, batched: true);
    }
    try {
      final events = coreEventsFromData(argumentsOf(frame));
      return record(events, batched: false);
    } catch (_) {
      // A frame the decoded path cannot read either is reported by the
      // transport and the batch is lost, exactly as before this reader.
      return record(const [], batched: false);
    }
  }

  _Recorder oracleEvents(Uint8List frame) {
    return record(coreEventsFromData(argumentsOf(frame)), batched: false);
  }

  void expectSameEvents(Uint8List frame) {
    final effective = effectiveEvents(frame);
    final oracle = oracleEvents(frame);
    expect(effective.logs, oracle.logs);
    expect(effective.requests, oracle.requests);
    expect(effective.dnsQueries, oracle.dnsQueries);
    expect(effective.traffic, oracle.traffic);
    expect(effective.loaded, oracle.loaded);
    expect(effective.crashes, oracle.crashes);
    expect(effective.dialerLoops, oracle.dialerLoops);
    expect(effective.delays, oracle.delays);
    expect(effective.geoUpdates, oracle.geoUpdates);
    expect(effective.routes, oracle.routes);
  }

  test('reads a batch with every event type the core writes', () {
    final frame = bytesOf(
      messageEnvelope([
        {
          'type': 'log',
          'data': {'LogLevel': 'info', 'Payload': 'plain'},
        },
        {
          'type': 'request',
          'data': {
            'id': 'c-1',
            'metadata': const {'network': 'tcp', 'host': 'example.com'},
            'upload': 1,
            'download': 2,
            'start': 1789705801000000,
            'chains': const ['Proxy'],
            'rule': 'MATCH',
            'rulePayload': '',
          },
        },
        {
          'type': 'dns',
          'data': {
            'domain': 'example.test',
            'type': 'A',
            'initiator': 'app',
            'answers': ['1.2.3.4'],
            'delay': 12,
            'time': 1789705801000000,
          },
        },
        {
          'type': 'requestTraffic',
          'data': [
            {'id': 'c-1', 'upload': 3, 'download': 4},
          ],
        },
        {'type': 'loaded', 'data': 'provider-a'},
        {'type': 'crash', 'data': 'boom'},
        {'type': 'dialerLoop', 'data': 'Front'},
        {
          'type': 'delay',
          'data': {
            'url': 'https://www.gstatic.com/generate_204',
            'name': 'node',
            'value': 42,
          },
        },
        {
          'type': 'geoUpdate',
          'data': {
            'type': 'geoip',
            'updating': true,
            'skipped': false,
            'error': '',
          },
        },
        {
          'type': 'routeChanged',
          'data': {'core-epoch': 3, 'route-version': 7},
        },
      ]),
    );

    final batch = messageBatchFromFrame(frame);
    expect(batch, isNotNull);
    expect(batch!.map((event) => event.type), [
      CoreEventType.log,
      CoreEventType.request,
      CoreEventType.dns,
      CoreEventType.requestTraffic,
      CoreEventType.loaded,
      CoreEventType.crash,
      CoreEventType.dialerLoop,
      CoreEventType.delay,
      CoreEventType.geoUpdate,
      CoreEventType.routeChanged,
    ]);
    expectSameEvents(frame);
  });

  test('leaves a frame that is not a message batch to the decoded path', () {
    expect(
      messageBatchFromFrame(
        bytesOf({'method': 'getTrafficStats', 'id': '1', 'arguments': null}),
      ),
      isNull,
    );
    expect(
      messageBatchFromFrame(
        bytesOf(const CoreMethodResponse(id: '1', result: {'up': 1}).toJson()),
      ),
      isNull,
    );
    expect(messageBatchFromFrame(utf8.encode('not json')), isNull);
    expect(messageBatchFromFrame(utf8.encode('')), isNull);
  });

  test('an unreadable message batch falls back whole', () {
    // The frame is cut off inside its second message, so no reader can take
    // the batch whole; the decoded path reports it and drops the batch.
    final frame = utf8.encode(
      '{"method":"message","arguments":['
      '{"type":"log","data":{"LogLevel":"info","Payload":"ok"}},'
      '{"type":"log","data":{"Payload":"truncated"}',
    );

    expect(messageBatchFromFrame(frame), isNull);
    expect(effectiveEvents(frame).logs, isEmpty);
  });

  test('a single message object is read like a list of one', () {
    final frame = bytesOf(
      messageEnvelope({'type': 'loaded', 'data': 'provider-single'}),
    );

    final batch = messageBatchFromFrame(frame);
    expect(batch?.single.type, CoreEventType.loaded);
    expectSameEvents(frame);
  });

  test('escapes survive the scan', () {
    const payloads = [
      'quote " backslash \\ slash /',
      'newline \n tab \t cr \r',
      'unicode \u00e9 \u4e2d \u{1F600}',
      'control \u0001 \u001f',
      'json in a string {"type":"crash","data":"trap"}',
      '","arguments":[{"type":"crash","data":"trap"}]}',
      'escaped \\u0041 \\ud83d\\ude00 pair',
    ];

    final frame = bytesOf(
      messageEnvelope([
        for (final payload in payloads)
          {
            'type': 'log',
            'data': {'LogLevel': 'warning', 'Payload': payload},
          },
        for (final payload in payloads) {'type': 'loaded', 'data': payload},
      ]),
    );

    final batch = messageBatchFromFrame(frame);
    expect(batch, isNotNull);
    expect(batch!.map((event) => event.data).toList(), containsAll(payloads));
    expectSameEvents(frame);
  });

  test('an escaped spelling of a key keeps reaching its field', () {
    // The fast path matches only the bytes the core writes, so a key
    // spelled with an escape sequence has to drop to the general path,
    // which reads the key as a string and dispatches on its unescaped
    // name; otherwise the field it names is silently lost.
    const head = '{"method":"message","arguments":[{';
    const mid = '"type":"log","data":{"LogLevel":"info",';
    const tail = ':"escaped payload"}}]}';
    const plain = '$head$mid"Payload"$tail';
    final escaped = '$head$mid"${String.fromCharCode(0x5C)}u0050ayload"$tail';

    expect(messageBatchFromFrame(utf8.encode(plain))?.single.data, isA<Log>());
    final log = messageBatchFromFrame(utf8.encode(escaped))?.single.data;
    expect(log, isA<Log>());
    expect((log as Log).payload, 'escaped payload');
    expectSameEvents(utf8.encode(escaped));
  });

  test('matches the decoded path on randomized batches', () {
    final random = Random(7);
    const levels = ['debug', 'info', 'warning', 'error', 'silent'];
    const dnsModes = ['normal', 'fake-ip', 'redir-host', 'hosts'];
    const initiators = ['app', 'rule', 'direct', 'proxy', 'other'];
    String payload() {
      const fragments = [
        'plain',
        'with "quotes"',
        'back\\slash',
        'tab\there',
        'newline\nhere',
        'unicode \u00e9\u4e2d\u{1F600}',
        'json {"type":"crash","data":"x"}',
        'control \u0007\u0010',
      ];
      final count = random.nextInt(3);
      return List.generate(
        count,
        (_) => fragments[random.nextInt(fragments.length)],
      ).join('|');
    }

    Object? randomRow() {
      final metadata = <String, Object?>{
        'network': random.nextBool() ? 'tcp' : 'udp',
        'host': payload(),
        'destinationIP': '10.0.0.${random.nextInt(255)}',
        'process': payload(),
      };
      if (random.nextBool()) metadata['uid'] = random.nextInt(9999);
      if (random.nextBool()) metadata['dnsMode'] = dnsModes[random.nextInt(4)];
      if (random.nextBool()) metadata['mitm'] = random.nextBool();
      if (random.nextBool()) {
        metadata['sourceGeoIP'] = List.generate(
          random.nextInt(3),
          (_) => 'AS${random.nextInt(999)}',
        );
      }
      return {
        'id': 'c-${random.nextInt(9999)}',
        'upload': random.nextInt(999999),
        'download': random.nextInt(999999),
        'start': 1789705801000000 + random.nextInt(999999),
        'metadata': metadata,
        'chains': List.generate(
          random.nextInt(3),
          (_) => 'Proxy-${random.nextInt(9)}',
        ),
        'rule': random.nextBool() ? 'MATCH' : payload(),
        'rulePayload': payload(),
      };
    }

    Object? randomMessage() {
      return switch (random.nextInt(9)) {
        0 => {
          'type': 'log',
          'data': {
            'LogLevel': levels[random.nextInt(levels.length)],
            'Payload': payload(),
          },
        },
        1 => {'type': 'request', 'data': randomRow()},
        2 => {
          'type': 'dns',
          'data': {
            'domain': payload(),
            'type': 'A',
            'initiator': initiators[random.nextInt(initiators.length)],
            'cached': random.nextBool(),
            'answers': List.generate(
              random.nextInt(3),
              (_) => '10.0.0.${random.nextInt(255)}',
            ),
            'delay': random.nextInt(999),
            'time': 1789705801000000 + random.nextInt(999999),
          },
        },
        3 => {
          'type': 'requestTraffic',
          'data': List.generate(
            random.nextInt(3),
            (_) => {
              'id': 'c-${random.nextInt(999)}',
              'upload': random.nextInt(999),
              'download': random.nextInt(999),
            },
          ),
        },
        4 => {'type': 'loaded', 'data': payload()},
        5 => {'type': 'crash', 'data': payload()},
        6 => {'type': 'dialerLoop', 'data': payload()},
        7 => {
          'type': 'delay',
          'data': {
            'url': 'https://www.gstatic.com/generate_204',
            'name': payload(),
            'value': random.nextInt(999),
          },
        },
        _ => {
          'type': 'geoUpdate',
          'data': {
            'type': random.nextBool() ? 'geoip' : 'geosite',
            'updating': random.nextBool(),
            'skipped': random.nextBool(),
            'error': random.nextBool() ? payload() : '',
          },
        },
      };
    }

    for (var attempt = 0; attempt < 60; attempt++) {
      final batch = List.generate(random.nextInt(30), (_) => randomMessage());
      expectSameEvents(bytesOf(messageEnvelope(batch)));
    }
  });
}
