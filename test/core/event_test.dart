import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingListener with CoreEventListener {
  _RecordingListener({
    this.onLoadedCallback,
    this.wantsRequestEvents = true,
    this.wantsDnsEvents = true,
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
        data: {'id': 'connection-1', 'metadata': <String, Object?>{}},
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
}
