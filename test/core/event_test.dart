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
  final List<TrackerInfo> requests = [];
  final List<DnsQuery> dnsQueries = [];
  final List<Log> logs = [];
  final List<Delay> delays = [];

  @override
  void onLoaded(String providerName) {
    loaded.add(providerName);
    onLoadedCallback?.call();
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

  @override
  void onDelay(Delay delay) {
    delays.add(delay);
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

  test(
    'a listener removed during dispatch is not called later in the snapshot',
    () {
      final second = _RecordingListener();
      late _RecordingListener first;
      first = _RecordingListener(
        onLoadedCallback: () => coreEventManager.removeListener(second),
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

      expect(first.loaded, ['provider-a']);
      expect(second.loaded, isEmpty);
    },
  );

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

  test('request and DNS interest is filtered per listener', () {
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

    expect(interested.requests, hasLength(1));
    expect(interested.dnsQueries, hasLength(1));
    expect(uninterested.requests, isEmpty);
    expect(uninterested.dnsQueries, isEmpty);
  });

  test('parses event data once when multiple listeners are registered', () {
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

    expect(first.logs.single.payload, 'shared-event');
    expect(second.logs.single.payload, 'shared-event');
    expect(identical(first.logs.single, second.logs.single), isTrue);
  });

  test('parses a delay event once for every listener', () {
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
        type: CoreEventType.delay,
        data: {'name': 'HK-01', 'url': 'https://example.test/204', 'value': 42},
      ),
    );

    expect(first.delays.single, second.delays.single);
    expect(identical(first.delays.single, second.delays.single), isTrue);
    expect(
      first.delays.single,
      const Delay(name: 'HK-01', url: 'https://example.test/204', value: 42),
    );
  });
}
