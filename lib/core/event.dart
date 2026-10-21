import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';

List<CoreEvent> coreEventsFromData(Object? data) {
  final items = data is List ? data : [data];
  final events = <CoreEvent>[];
  for (final item in items.whereType<Map>()) {
    try {
      events.add(CoreEvent.fromJson(Map<String, Object?>.from(item)));
    } catch (error) {
      commonPrint.log(
        'Unable to parse Core event: $error',
        logLevel: LogLevel.error,
      );
    }
  }
  return events;
}

abstract mixin class CoreEventListener {
  bool get wantsRequestEvents => false;

  bool get wantsDnsEvents => false;

  void onLog(Log log) {}

  void onDelay(Delay delay) {}

  void onRequest(TrackerInfo connection) {}

  void onRequestTraffic(Map<String, RequestTraffic> traffic) {}

  void onDns(DnsQuery dnsQuery) {}

  void onLoaded(String providerName) {}

  void onCrash(String message) {}

  void onGeoUpdate(
    String geoType,
    bool updating,
    bool skipped,
    String? error,
  ) {}

  void onRouteChanged(RouteSnapshot snapshot) {}

  void onDialerLoop(String proxyName) {}
}

class CoreEventManager {
  CoreEventManager._();

  static final CoreEventManager instance = CoreEventManager._();

  static bool _wantsRequests(CoreEventListener listener) =>
      listener.wantsRequestEvents;

  static bool _wantsDnsQueries(CoreEventListener listener) =>
      listener.wantsDnsEvents;

  final ObserverList<CoreEventListener> _listeners =
      ObserverList<CoreEventListener>();
  List<CoreEventListener>? _listenerSnapshot;

  bool get hasListeners {
    return _listeners.isNotEmpty;
  }

  /// Dispatches on the calling stack so a disposed listener is not hit by a
  /// late stream microtask after the widget tree is already torn down.
  void sendEvent(CoreEvent event) {
    final listeners = _listenerSnapshot ??= List.unmodifiable(_listeners);
    if (listeners.isEmpty) {
      return;
    }
    final filter = _filterFor(event);
    if (filter != null && !listeners.any(filter)) {
      return;
    }
    Object? payload;
    try {
      payload = _parseEventPayload(event);
    } catch (error) {
      commonPrint.log(
        'Unable to parse Core event ${event.type.name}: $error',
        logLevel: LogLevel.error,
      );
      return;
    }
    for (final listener in listeners) {
      if (filter == null || filter(listener)) {
        _sendToListener(listener, event, payload);
      }
    }
  }

  static bool Function(CoreEventListener listener)? _filterFor(
    CoreEvent event,
  ) {
    return switch (event.type) {
      CoreEventType.request => _wantsRequests,
      CoreEventType.dns => _wantsDnsQueries,
      _ => null,
    };
  }

  void addListener(CoreEventListener listener) {
    _listeners.add(listener);
    _listenerSnapshot = null;
  }

  void removeListener(CoreEventListener listener) {
    _listeners.remove(listener);
    _listenerSnapshot = null;
  }

  Object? _parseEventPayload(CoreEvent event) {
    switch (event.type) {
      case CoreEventType.log:
        return Log.fromJson(_eventData(event));
      case CoreEventType.delay:
        return Delay.fromJson(_eventData(event));
      case CoreEventType.request:
        return TrackerInfo.fromJson(_eventData(event));
      case CoreEventType.requestTraffic:
        return {
          for (final Map item in event.data as List)
            item['id'] as String: (
              upload: (item['upload'] as num).toInt(),
              download: (item['download'] as num).toInt(),
            ),
        };
      case CoreEventType.dns:
        return DnsQuery.fromJson(_eventData(event));
      case CoreEventType.loaded:
      case CoreEventType.crash:
        return '${event.data}';
      case CoreEventType.geoUpdate:
        final data = _eventData(event);
        return _GeoUpdatePayload(
          geoType: data['type'] as String,
          updating: data['updating'] as bool,
          skipped: data['skipped'] as bool? ?? false,
          error: data['error'] as String?,
        );
      case CoreEventType.routeChanged:
        return RouteSnapshot.fromJson(_eventData(event));
      case CoreEventType.dialerLoop:
        return event.data as String;
    }
  }

  /// Transport events already carry `Map<String, Object?>`; avoid re-copying.
  static Map<String, Object?> _eventData(CoreEvent event) {
    final data = event.data;
    return data is Map<String, Object?>
        ? data
        : Map<String, Object?>.from(data as Map);
  }
}

void _sendToListener(
  CoreEventListener listener,
  CoreEvent event,
  Object? payload,
) {
  try {
    switch (event.type) {
      case CoreEventType.log:
        listener.onLog(payload as Log);
        break;
      case CoreEventType.delay:
        listener.onDelay(payload as Delay);
        break;
      case CoreEventType.request:
        listener.onRequest(payload as TrackerInfo);
        break;
      case CoreEventType.requestTraffic:
        listener.onRequestTraffic(payload as Map<String, RequestTraffic>);
        break;
      case CoreEventType.dns:
        listener.onDns(payload as DnsQuery);
        break;
      case CoreEventType.loaded:
        listener.onLoaded(payload as String);
        break;
      case CoreEventType.crash:
        listener.onCrash(payload as String);
        break;
      case CoreEventType.geoUpdate:
        final geoUpdate = payload as _GeoUpdatePayload;
        listener.onGeoUpdate(
          geoUpdate.geoType,
          geoUpdate.updating,
          geoUpdate.skipped,
          geoUpdate.error,
        );
        break;
      case CoreEventType.routeChanged:
        listener.onRouteChanged(payload as RouteSnapshot);
        break;
      case CoreEventType.dialerLoop:
        listener.onDialerLoop(payload as String);
        break;
    }
  } catch (error) {
    commonPrint.log(
      'Unable to dispatch Core event ${event.type.name}: $error',
      logLevel: LogLevel.error,
    );
  }
}

class _GeoUpdatePayload {
  const _GeoUpdatePayload({
    required this.geoType,
    required this.updating,
    required this.skipped,
    this.error,
  });

  final String geoType;
  final bool updating;
  final bool skipped;
  final String? error;
}

final coreEventManager = CoreEventManager.instance;
