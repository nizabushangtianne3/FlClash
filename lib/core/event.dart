import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';

List<CoreEvent> coreEventsFromData(Object? data) {
  final items = data is List ? data : [data];
  final events = <CoreEvent>[];
  for (final item in items) {
    if (item is! Map<String, Object?>) continue;
    try {
      events.add(coreEventFrom(item));
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

/// Reads one {"type":...,"data":...} envelope by matching the wire name
/// directly, ordered by how often the feed carries each one; the enum's
/// reverse lookup costs more than the strings do at this volume.
CoreEvent coreEventFrom(Map<String, Object?> json) {
  return CoreEvent(
    type: switch (json['type'] as String) {
      'log' => CoreEventType.log,
      'dns' => CoreEventType.dns,
      'request' => CoreEventType.request,
      'requestTraffic' => CoreEventType.requestTraffic,
      'delay' => CoreEventType.delay,
      'loaded' => CoreEventType.loaded,
      'crash' => CoreEventType.crash,
      'geoUpdate' => CoreEventType.geoUpdate,
      'routeChanged' => CoreEventType.routeChanged,
      'dialerLoop' => CoreEventType.dialerLoop,
      _ => throw ArgumentError.value(json['type'], 'type', 'unknown event'),
    },
    data: json['data'],
  );
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
    _dispatch(event, DateTime.now());
  }

  /// Dispatches the whole batch one flush carried with a single arrival
  /// clock: the logs in it reached the host together and share their moment.
  void sendEvents(List<CoreEvent> events) {
    final clock = DateTime.now();
    for (final event in events) {
      _dispatch(event, clock);
    }
  }

  void _dispatch(CoreEvent event, DateTime clock) {
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
      payload = _parseEventPayload(event, clock);
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

  /// The payload an event carries to its listeners. The decoded path hands
  /// over the map the frame produced and the model is built here; the reader
  /// in event_json.dart hands the model over already built, so a payload
  /// that arrived built is passed through untouched.
  Object? _parseEventPayload(CoreEvent event, DateTime clock) {
    final data = event.data;
    switch (event.type) {
      case CoreEventType.log:
        return data is Log ? data : logFromData(_eventData(event), clock);
      case CoreEventType.delay:
        return data is Delay ? data : Delay.fromJson(_eventData(event));
      case CoreEventType.request:
        return data is TrackerInfo
            ? data
            : trackerInfoFromData(_eventData(event));
      case CoreEventType.requestTraffic:
        if (data is Map<String, RequestTraffic>) {
          return data;
        }
        return {
          for (final Map item in data as List)
            item['id'] as String: (
              upload: (item['upload'] as num).toInt(),
              download: (item['download'] as num).toInt(),
            ),
        };
      case CoreEventType.dns:
        return data is DnsQuery ? data : DnsQuery.fromJson(_eventData(event));
      case CoreEventType.loaded:
      case CoreEventType.crash:
        return data is String ? data : '${event.data}';
      case CoreEventType.geoUpdate:
        if (data is GeoUpdatePayload) {
          return data;
        }
        final map = _eventData(event);
        return GeoUpdatePayload(
          geoType: map['type'] as String,
          updating: map['updating'] as bool,
          skipped: map['skipped'] as bool? ?? false,
          error: map['error'] as String?,
        );
      case CoreEventType.routeChanged:
        return data is RouteSnapshot
            ? data
            : RouteSnapshot.fromJson(_eventData(event));
      case CoreEventType.dialerLoop:
        return data is String ? data : event.data as String;
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
        final geoUpdate = payload as GeoUpdatePayload;
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

class GeoUpdatePayload {
  const GeoUpdatePayload({
    required this.geoType,
    required this.updating,
    required this.skipped,
    this.error,
  });

  final String geoType;
  final bool updating;
  final bool skipped;
  final String? error;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is GeoUpdatePayload &&
            other.geoType == geoType &&
            other.updating == updating &&
            other.skipped == skipped &&
            other.error == error);
  }

  @override
  int get hashCode => Object.hash(geoType, updating, skipped, error);
}

final coreEventManager = CoreEventManager.instance;
