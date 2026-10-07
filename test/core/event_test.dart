import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingListener with CoreEventListener {
  _RecordingListener({
    this.onLoadedCallback,
    this.wantsRequestEvents = false,
    this.wantsDnsEvents = false,
  });

  final void Function()? onLoadedCallback;
  @override
  final bool wantsRequestEvents;
  @override
  final bool wantsDnsEvents;
  final List<String> loaded = [];
  final List<String> dialerLoops = [];
  final List<TrackerInfo> requests = [];
  final List<DnsQuery> dnsQueries = [];
  final List<Log> logs = [];

  @override
  void onLoaded(String providerName) {
    loaded.add(providerName);
    onLoadedCallback?.call();
  }

  @override
  void onDialerLoop(String proxyName) {
    dialerLoops.add(proxyName);
  }

  @override
  void onRequest(TrackerInfo connection) {
    requests.add(connection);
  }

  @override
  void onDns(DnsQuery dnsQuery) {
    dnsQueries.add(dnsQuery);
  }

  @override
  void onLog(Log log) {
    logs.add(log);
  }
}

void main() {
  test(
    'a listener may unregister itself while an event is dispatched',
    () async {
      late _RecordingListener first;
      final second = _RecordingListener();
      first = _RecordingListener(
        onLoadedCallback: () => coreEventManager.removeListener(first),
      );

      coreEventManager.addListener(first);
      coreEventManager.addListener(second);
      addTearDown(() {
        coreEventManager.removeListener(first);
        coreEventManager.removeListener(second);
      });

      coreEventManager.sendEvent(
        const CoreEvent(type: CoreEventType.loaded, data: 'provider-a'),
      );
      await pumpEventQueue();

      expect(first.loaded, ['provider-a']);
      expect(second.loaded, ['provider-a']);

      coreEventManager.sendEvent(
        const CoreEvent(type: CoreEventType.loaded, data: 'provider-b'),
      );
      await pumpEventQueue();

      expect(first.loaded, ['provider-a']);
      expect(second.loaded, ['provider-a', 'provider-b']);
    },
  );

  test('a dialer loop the core stopped reaches the listeners', () async {
    final listener = _RecordingListener();
    coreEventManager.addListener(listener);
    addTearDown(() => coreEventManager.removeListener(listener));

    coreEventsFromData({
      'type': 'dialerLoop',
      'data': 'Front',
    }).forEach(coreEventManager.sendEvent);
    await pumpEventQueue();

    expect(listener.dialerLoops, ['Front']);
  });

  test('skips request and DNS parsing when no listener wants them', () {
    final listener = _RecordingListener(
      wantsRequestEvents: false,
      wantsDnsEvents: false,
    );
    coreEventManager.addListener(listener);
    addTearDown(() => coreEventManager.removeListener(listener));

    coreEventManager.sendEvent(
      const CoreEvent(
        type: CoreEventType.request,
        data: {
          'id': 'connection-1',
          'metadata': {'network': 'tcp'},
          'upload': 0,
          'download': 0,
          'start': '2026-09-18T04:30:01Z',
          'chains': <String>[],
          'rule': 'MATCH',
          'rulePayload': '',
        },
      ),
    );
    coreEventManager.sendEvent(
      const CoreEvent(
        type: CoreEventType.dns,
        data: {
          'domain': 'example.test',
          'type': 'A',
          'time': '2026-09-18T04:30:01Z',
        },
      ),
    );

    expect(listener.requests, isEmpty);
    expect(listener.dnsQueries, isEmpty);
  });

  test('listeners default to no request or DNS interest', () {
    final listener = _RecordingListener();
    coreEventManager.addListener(listener);
    addTearDown(() => coreEventManager.removeListener(listener));

    coreEventManager.sendEvent(
      const CoreEvent(
        type: CoreEventType.request,
        data: {
          'id': 'connection-1',
          'metadata': {'network': 'tcp'},
          'upload': 0,
          'download': 0,
          'start': '2026-09-18T04:30:01Z',
          'chains': <String>[],
          'rule': 'MATCH',
          'rulePayload': '',
        },
      ),
    );
    coreEventManager.sendEvent(
      const CoreEvent(
        type: CoreEventType.dns,
        data: {
          'domain': 'example.test',
          'type': 'A',
          'time': '2026-09-18T04:30:01Z',
        },
      ),
    );

    expect(listener.requests, isEmpty);
    expect(listener.dnsQueries, isEmpty);
  });

  test('request and DNS interest is filtered per listener', () async {
    final interested = _RecordingListener(
      wantsRequestEvents: true,
      wantsDnsEvents: true,
    );
    final uninterested = _RecordingListener();
    coreEventManager.addListener(interested);
    coreEventManager.addListener(uninterested);
    addTearDown(() {
      coreEventManager.removeListener(interested);
      coreEventManager.removeListener(uninterested);
    });

    coreEventManager.sendEvent(
      const CoreEvent(
        type: CoreEventType.request,
        data: {
          'id': 'connection-1',
          'metadata': {'network': 'tcp'},
          'upload': 0,
          'download': 0,
          'start': '2026-09-18T04:30:01Z',
          'chains': <String>[],
          'rule': 'MATCH',
          'rulePayload': '',
        },
      ),
    );
    coreEventManager.sendEvent(
      const CoreEvent(
        type: CoreEventType.dns,
        data: {
          'domain': 'example.test',
          'type': 'A',
          'time': '2026-09-18T04:30:01Z',
        },
      ),
    );
    await pumpEventQueue();

    expect(interested.requests, hasLength(1));
    expect(interested.dnsQueries, hasLength(1));
    expect(uninterested.requests, isEmpty);
    expect(uninterested.dnsQueries, isEmpty);
  });

  test('parses event data once when multiple listeners are registered', () async {
    final first = _RecordingListener();
    final second = _RecordingListener();
    coreEventManager.addListener(first);
    coreEventManager.addListener(second);
    addTearDown(() {
      coreEventManager.removeListener(first);
      coreEventManager.removeListener(second);
    });

    coreEventManager.sendEvent(
      const CoreEvent(
        type: CoreEventType.log,
        data: {'LogLevel': 'info', 'Payload': 'shared-event'},
      ),
    );
    await pumpEventQueue();

    expect(first.logs.single.payload, 'shared-event');
    expect(second.logs.single.payload, 'shared-event');
    expect(identical(first.logs.single, second.logs.single), isTrue);
  });
}
