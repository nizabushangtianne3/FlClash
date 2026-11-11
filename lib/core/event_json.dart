import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

/// Reads the event batch a core flush writes straight off its text.
///
/// The generic decoder builds two maps per message — the envelope and the
/// payload — only for the readers to walk them a moment later, and each read
/// then pays cold-cache lookups on freshly allocated tables. This reads the
/// batch once during the scan: the envelope, the log rows, the connection
/// rows, the DNS queries and the traffic counters are built as the bytes are
/// walked, and only the rare payload shapes fall back to a decode of their
/// own slice.
///
/// A frame that is not a message batch, or one this reader cannot read
/// whole, returns null and leaves the caller to the decoded path, which
/// stays this reader's oracle in the tests and its safety net in production.
List<CoreEvent>? messageBatchFromFrame(Uint8List frame) {
  try {
    return _FrameScanner(utf8.decode(frame)).readBatch();
  } catch (error) {
    return null;
  }
}

/// Key codes: a wire field name goes through a table once and the readers
/// switch on a small int, which the VM turns into a jump instead of the
/// string comparisons a switch on the names would walk.
const _logKeyCodes = <String, int>{'LogLevel': 1, 'Payload': 2};

const _rowKeyCodes = <String, int>{
  'metadata': 1,
  'id': 2,
  'upload': 3,
  'download': 4,
  'start': 5,
  'chains': 6,
  'rule': 7,
  'rulePayload': 8,
  'downloadSpeed': 9,
  'uploadSpeed': 10,
};

const _metadataKeyCodes = <String, int>{
  'uid': 1,
  'network': 2,
  'sourceIP': 3,
  'sourcePort': 4,
  'destinationIP': 5,
  'destinationPort': 6,
  'host': 7,
  'dnsMode': 8,
  'process': 9,
  'processPath': 10,
  'remoteDestination': 11,
  'sourceGeoIP': 12,
  'destinationGeoIP': 13,
  'destinationIPASN': 14,
  'sourceIPASN': 15,
  'specialRules': 16,
  'specialProxy': 17,
  'mitm': 18,
  'mitmRefused': 19,
};

const _dnsKeyCodes = <String, int>{
  'domain': 1,
  'type': 2,
  'initiator': 3,
  'upstream': 4,
  'cached': 5,
  'answers': 6,
  'rcode': 7,
  'error': 8,
  'delay': 9,
  'time': 10,
};

const _trafficKeyCodes = <String, int>{'id': 1, 'upload': 2, 'download': 3};

class _FrameScanner {
  _FrameScanner(this._text);

  final String _text;
  int _at = 0;

  /// The clock the batch's logs carry: the logs one flush wrote reached the
  /// host together, so one read serves the batch.
  late final DateTime _clock = DateTime.now();

  List<CoreEvent>? readBatch() {
    _skipWhitespace();
    if (_code() != 0x7B) return null;
    _at++;
    String? method;
    List<CoreEvent>? batch;
    _skipWhitespace();
    if (_code() == 0x7D) return null;
    while (true) {
      _skipWhitespace();
      if (_code() != 0x22) return null;
      final key = _readString();
      _skipWhitespace();
      if (_code() != 0x3A) return null;
      _at++;
      _skipWhitespace();
      if (key == 'method') {
        if (_code() != 0x22) return null;
        method = _readString();
      } else if (key == 'arguments') {
        if (method != CoreMethod.message.wireName) return null;
        batch = _readMessages();
      } else {
        _skipValue();
      }
      _skipWhitespace();
      final next = _code();
      if (next == 0x7D) break;
      if (next != 0x2C) return null;
      _at++;
    }
    return batch;
  }

  List<CoreEvent> _readMessages() {
    final events = <CoreEvent>[];
    _skipWhitespace();
    if (_code() != 0x5B) {
      final single = _readMessage();
      if (single != null) {
        events.add(single);
      }
      return events;
    }
    _at++;
    _skipWhitespace();
    if (_code() == 0x5D) {
      _at++;
      return events;
    }
    while (true) {
      final event = _readMessage();
      if (event != null) {
        events.add(event);
      }
      _skipWhitespace();
      final next = _code();
      if (next == 0x5D) {
        _at++;
        return events;
      }
      if (next != 0x2C) throw const FormatException('batch item');
      _at++;
    }
  }

  /// Reads one {"type":...,"data":...} envelope. A malformed item throws, and
  /// the whole frame then falls back to the decoded path, which logs and
  /// drops it exactly as it always did.
  CoreEvent? _readMessage() {
    _skipWhitespace();
    if (_code() != 0x7B) {
      _skipValue();
      return null;
    }
    _at++;
    String? type;
    int dataStart = -1;
    int dataEnd = -1;
    _skipWhitespace();
    if (_code() != 0x7D) {
      while (true) {
        _skipWhitespace();
        final key = _readString();
        _skipWhitespace();
        if (_code() != 0x3A) throw const FormatException('field');
        _at++;
        _skipWhitespace();
        if (key == 'type') {
          if (_code() != 0x22) throw const FormatException('type');
          type = _readString();
        } else if (key == 'data') {
          dataStart = _at;
          _skipValue();
          dataEnd = _at;
        } else {
          _skipValue();
        }
        _skipWhitespace();
        final next = _code();
        if (next == 0x7D) break;
        if (next != 0x2C) throw const FormatException('field end');
        _at++;
      }
    }
    _at++;
    if (type == null) throw const FormatException('type');
    if (dataStart < 0) throw const FormatException('data');
    final messageEnd = _at;
    final event = _build(type, dataStart, dataEnd);
    _at = messageEnd;
    return event;
  }

  CoreEvent _build(String type, int dataStart, int dataEnd) {
    final coreType = _eventTypeOf(type);
    if (coreType == null) {
      throw ArgumentError.value(type, 'type', 'unknown event');
    }
    switch (coreType) {
      case CoreEventType.log:
        _at = dataStart;
        _requireObject('log payload');
        return CoreEvent(type: coreType, data: _readLogPayload(_clock));
      case CoreEventType.request:
        _at = dataStart;
        _requireObject('connection row');
        return CoreEvent(type: coreType, data: _readRow());
      case CoreEventType.dns:
        _at = dataStart;
        _requireObject('dns query');
        return CoreEvent(type: coreType, data: _readDnsQuery());
      case CoreEventType.requestTraffic:
        _at = dataStart;
        _skipWhitespace();
        if (_code() != 0x5B) throw const FormatException('traffic counters');
        return CoreEvent(type: coreType, data: _readTraffic());
      case CoreEventType.loaded:
      case CoreEventType.crash:
      case CoreEventType.dialerLoop:
        return CoreEvent(type: coreType, data: _readTextOrSlice(dataStart));
      case CoreEventType.delay:
        return CoreEvent(
          type: coreType,
          data: Delay.fromJson(_slice(dataStart, dataEnd)),
        );
      case CoreEventType.geoUpdate:
        final data = _slice(dataStart, dataEnd);
        return CoreEvent(
          type: coreType,
          data: GeoUpdatePayload(
            geoType: data['type'] as String,
            updating: data['updating'] as bool,
            skipped: data['skipped'] as bool? ?? false,
            error: data['error'] as String?,
          ),
        );
      case CoreEventType.routeChanged:
        return CoreEvent(
          type: coreType,
          data: RouteSnapshot.fromJson(_slice(dataStart, dataEnd)),
        );
    }
  }

  /// The decoded path renders whatever it got as text, so a plain value keeps
  /// its literal text here and a string keeps its unescaped value.
  String _readTextOrSlice(int dataStart) {
    _at = dataStart;
    if (_code() == 0x22) {
      return _readString();
    }
    _skipValue();
    return _text.substring(dataStart, _at);
  }

  CoreEventType? _eventTypeOf(String name) {
    return switch (name) {
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
      _ => null,
    };
  }

  void _requireObject(String what) {
    _skipWhitespace();
    if (_code() != 0x7B) throw FormatException(what);
  }

  Log _readLogPayload(DateTime clock) {
    var level = LogLevel.info;
    var payload = '';
    _at++;
    _skipWhitespace();
    if (_code() != 0x7D) {
      while (true) {
        _skipWhitespace();
        final key = _readString();
        _skipWhitespace();
        if (_code() != 0x3A) throw const FormatException('field');
        _at++;
        _skipWhitespace();
        switch (_logKeyCodes[key] ?? 0) {
          case 1:
            if (_code() == 0x22) {
              level = logLevelOf(_readString()) ?? LogLevel.info;
            } else {
              _skipValue();
            }
          case 2:
            if (_code() == 0x22) {
              payload = _readString();
            } else {
              _skipValue();
            }
          default:
            _skipValue();
        }
        _skipWhitespace();
        final next = _code();
        if (next == 0x7D) break;
        if (next != 0x2C) throw const FormatException('field end');
        _at++;
      }
    }
    _skipWhitespace();
    if (_code() != 0x7D) throw const FormatException('log payload');
    _at++;
    return Log(logLevel: level, payload: payload, dateTime: clock);
  }

  TrackerInfo _readRow() {
    var id = '';
    var upload = 0;
    var download = 0;
    var start = 0;
    var chains = const <String>[];
    var rule = '';
    var rulePayload = '';
    int? downloadSpeed;
    int? uploadSpeed;
    Metadata? metadata;
    _at++;
    _skipWhitespace();
    if (_code() != 0x7D) {
      while (true) {
        _skipWhitespace();
        final key = _readString();
        _skipWhitespace();
        if (_code() != 0x3A) throw const FormatException('field');
        _at++;
        _skipWhitespace();
        switch (_rowKeyCodes[key] ?? 0) {
          case 2:
            id = _readString();
          case 3:
            upload = _readInt();
          case 4:
            download = _readInt();
          case 5:
            start = _readInt();
          case 6:
            chains = _readStringList() ?? const [];
          case 7:
            rule = _readString();
          case 8:
            rulePayload = _readString();
          case 9:
            downloadSpeed = _readOptionalInt();
          case 10:
            uploadSpeed = _readOptionalInt();
          case 1:
            _at++;
            metadata = _readMetadata();
          default:
            _skipValue();
        }
        _skipWhitespace();
        final next = _code();
        if (next == 0x7D) break;
        if (next != 0x2C) throw const FormatException('field end');
        _at++;
      }
    }
    _at++;
    if (metadata == null) throw const FormatException('metadata');
    return TrackerInfo(
      id: id,
      upload: upload,
      download: download,
      start: DateTime.fromMicrosecondsSinceEpoch(start, isUtc: true),
      metadata: metadata,
      chains: chains,
      rule: rule,
      rulePayload: rulePayload,
      downloadSpeed: downloadSpeed,
      uploadSpeed: uploadSpeed,
    );
  }

  Metadata _readMetadata() {
    var uid = 0;
    var network = '';
    var sourceIP = '';
    var sourcePort = '';
    var destinationIP = '';
    var destinationPort = '';
    var host = '';
    DnsMode? dnsMode;
    var process = '';
    var processPath = '';
    var remoteDestination = '';
    var sourceGeoIP = const <String>[];
    var destinationGeoIP = const <String>[];
    var destinationIPASN = '';
    var sourceIPASN = '';
    var specialRules = '';
    var specialProxy = '';
    var mitm = false;
    var mitmRefused = false;
    _skipWhitespace();
    if (_code() != 0x7D) {
      while (true) {
        _skipWhitespace();
        final key = _readString();
        _skipWhitespace();
        if (_code() != 0x3A) throw const FormatException('field');
        _at++;
        _skipWhitespace();
        switch (_metadataKeyCodes[key] ?? 0) {
          case 1:
            uid = _readInt();
          case 2:
            network = _readString();
          case 3:
            sourceIP = _readString();
          case 4:
            sourcePort = _readString();
          case 5:
            destinationIP = _readString();
          case 6:
            destinationPort = _readString();
          case 7:
            host = _readString();
          case 8:
            if (_code() == 0x22) {
              dnsMode = dnsModeOf(_readString());
            } else {
              _skipValue();
            }
          case 9:
            process = _readString();
          case 10:
            processPath = _readString();
          case 11:
            remoteDestination = _readString();
          case 12:
            sourceGeoIP = _readStringList() ?? const [];
          case 13:
            destinationGeoIP = _readStringList() ?? const [];
          case 14:
            destinationIPASN = _readString();
          case 15:
            sourceIPASN = _readString();
          case 16:
            specialRules = _readString();
          case 17:
            specialProxy = _readString();
          case 18:
            mitm = _readBool();
          case 19:
            mitmRefused = _readBool();
          default:
            _skipValue();
        }
        _skipWhitespace();
        final next = _code();
        if (next == 0x7D) break;
        if (next != 0x2C) throw const FormatException('field end');
        _at++;
      }
    }
    _skipWhitespace();
    if (_code() != 0x7D) throw const FormatException('metadata');
    _at++;
    return Metadata(
      uid: uid,
      network: network,
      sourceIP: sourceIP,
      sourcePort: sourcePort,
      destinationIP: destinationIP,
      destinationPort: destinationPort,
      host: host,
      dnsMode: dnsMode,
      process: process,
      processPath: processPath,
      remoteDestination: remoteDestination,
      sourceGeoIP: sourceGeoIP,
      destinationGeoIP: destinationGeoIP,
      destinationIPASN: destinationIPASN,
      sourceIPASN: sourceIPASN,
      specialRules: specialRules,
      specialProxy: specialProxy,
      mitm: mitm,
      mitmRefused: mitmRefused,
    );
  }

  DnsQuery _readDnsQuery() {
    var domain = '';
    var type = '';
    DnsQueryInitiator? initiator;
    var upstream = '';
    var cached = false;
    var answers = const <String>[];
    var rcode = '';
    var error = '';
    var delay = 0;
    var time = 0;
    _at++;
    _skipWhitespace();
    if (_code() != 0x7D) {
      while (true) {
        _skipWhitespace();
        final key = _readString();
        _skipWhitespace();
        if (_code() != 0x3A) throw const FormatException('field');
        _at++;
        _skipWhitespace();
        switch (_dnsKeyCodes[key] ?? 0) {
          case 1:
            domain = _readString();
          case 2:
            type = _readString();
          case 3:
            if (_code() == 0x22) {
              initiator = _initiatorOf(_readString());
            } else {
              _skipValue();
            }
          case 4:
            upstream = _readString();
          case 5:
            cached = _readBool();
          case 6:
            answers = _readStringList() ?? const [];
          case 7:
            rcode = _readString();
          case 8:
            error = _readString();
          case 9:
            delay = _readInt();
          case 10:
            time = _readInt();
          default:
            _skipValue();
        }
        _skipWhitespace();
        final next = _code();
        if (next == 0x7D) break;
        if (next != 0x2C) throw const FormatException('field end');
        _at++;
      }
    }
    _at++;
    return DnsQuery(
      domain: domain,
      type: type,
      initiator: initiator,
      upstream: upstream,
      cached: cached,
      answers: answers,
      rcode: rcode,
      error: error,
      delay: delay,
      time: DateTime.fromMicrosecondsSinceEpoch(time, isUtc: true),
    );
  }

  DnsQueryInitiator? _initiatorOf(String value) {
    return switch (value) {
      'app' => DnsQueryInitiator.app,
      'rule' => DnsQueryInitiator.rule,
      'direct' => DnsQueryInitiator.direct,
      'proxy' => DnsQueryInitiator.proxy,
      'other' => DnsQueryInitiator.other,
      _ => null,
    };
  }

  Map<String, RequestTraffic> _readTraffic() {
    final traffic = <String, RequestTraffic>{};
    _at++;
    _skipWhitespace();
    if (_code() == 0x5D) {
      _at++;
      return traffic;
    }
    while (true) {
      var id = '';
      var upload = 0;
      var download = 0;
      _skipWhitespace();
      if (_code() != 0x7B) throw const FormatException('counter');
      _at++;
      _skipWhitespace();
      if (_code() != 0x7D) {
        while (true) {
          _skipWhitespace();
          final key = _readString();
          _skipWhitespace();
          if (_code() != 0x3A) throw const FormatException('field');
          _at++;
          _skipWhitespace();
          switch (_trafficKeyCodes[key] ?? 0) {
            case 1:
              id = _readString();
            case 2:
              upload = _readInt();
            case 3:
              download = _readInt();
            default:
              _skipValue();
          }
          _skipWhitespace();
          final next = _code();
          if (next == 0x7D) break;
          if (next != 0x2C) throw const FormatException('field end');
          _at++;
        }
      }
      _at++;
      traffic[id] = (upload: upload, download: download);
      _skipWhitespace();
      final next = _code();
      if (next == 0x5D) {
        _at++;
        return traffic;
      }
      if (next != 0x2C) throw const FormatException('counter end');
      _at++;
    }
  }

  Map<String, Object?> _slice(int start, int end) {
    final decoded = jsonDecode(_text.substring(start, end));
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) return Map<String, Object?>.from(decoded);
    throw const FormatException('slice');
  }

  int _code() {
    if (_at >= _text.length) throw const FormatException('end of frame');
    return _text.codeUnitAt(_at);
  }

  /// Reads a JSON string starting at its opening quote and returns it
  /// unescaped; the closing quote is consumed.
  String _readString() {
    final text = _text;
    if (_code() != 0x22) throw const FormatException('string');
    var at = _at + 1;
    final start = at;
    while (at < text.length) {
      final unit = text.codeUnitAt(at);
      if (unit == 0x22) {
        _at = at + 1;
        return text.substring(start, at);
      }
      if (unit == 0x5C) break;
      at++;
    }
    return _readEscapedString(start, at);
  }

  String _readEscapedString(int start, int breakAt) {
    final text = _text;
    final buffer = StringBuffer(text.substring(start, breakAt));
    var at = breakAt;
    while (at < text.length) {
      final unit = text.codeUnitAt(at);
      if (unit == 0x22) {
        _at = at + 1;
        return buffer.toString();
      }
      if (unit != 0x5C) {
        final runStart = at;
        do {
          at++;
        } while (at < text.length &&
            text.codeUnitAt(at) != 0x22 &&
            text.codeUnitAt(at) != 0x5C);
        buffer.write(text.substring(runStart, at));
        continue;
      }
      at++;
      if (at >= text.length) throw const FormatException('escape');
      switch (text.codeUnitAt(at)) {
        case 0x22:
          buffer.writeCharCode(0x22);
        case 0x5C:
          buffer.writeCharCode(0x5C);
        case 0x2F:
          buffer.writeCharCode(0x2F);
        case 0x62:
          buffer.writeCharCode(0x08);
        case 0x66:
          buffer.writeCharCode(0x0C);
        case 0x6E:
          buffer.writeCharCode(0x0A);
        case 0x72:
          buffer.writeCharCode(0x0D);
        case 0x74:
          buffer.writeCharCode(0x09);
        case 0x75:
          final code = _readHex(at + 1);
          at += 4;
          if (code >= 0xD800 &&
              code <= 0xDBFF &&
              at + 6 < text.length &&
              text.codeUnitAt(at + 1) == 0x75 &&
              text.codeUnitAt(at + 2) == 0x5C) {
            final low = _readHex(at + 3);
            if (low >= 0xDC00 && low <= 0xDFFF) {
              buffer.writeCharCode(
                0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00),
              );
              at += 6;
              break;
            }
          }
          buffer.writeCharCode(code);
        default:
          throw const FormatException('escape');
      }
      at++;
    }
    throw const FormatException('string');
  }

  int _readHex(int at) {
    var code = 0;
    for (var i = 0; i < 4; i++) {
      if (at + i >= _text.length) throw const FormatException('hex');
      final unit = _text.codeUnitAt(at + i);
      final digit = switch (unit) {
        >= 0x30 && <= 0x39 => unit - 0x30,
        >= 0x61 && <= 0x66 => unit - 0x61 + 10,
        >= 0x41 && <= 0x46 => unit - 0x41 + 10,
        _ => throw const FormatException('hex'),
      };
      code = (code << 4) | digit;
    }
    return code;
  }

  /// Advances past a JSON string without materialising it: a value the wire
  /// carries that no model reads never needs its text, and the metadata a
  /// row wears is mostly such values.
  void _skipString() {
    final text = _text;
    if (_code() != 0x22) throw const FormatException('string');
    var at = _at + 1;
    while (at < text.length) {
      final unit = text.codeUnitAt(at);
      if (unit == 0x22) {
        _at = at + 1;
        return;
      }
      if (unit == 0x5C) {
        at++;
      }
      at++;
    }
    throw const FormatException('string');
  }

  int _readInt() {
    final value = _readNumber();
    if (value is! int) throw const FormatException('number');
    return value;
  }

  int? _readOptionalInt() {
    _skipWhitespace();
    if (_code() == 0x6E) {
      _skipValue();
      return null;
    }
    return _readInt();
  }

  num _readNumber() {
    _skipWhitespace();
    final start = _at;
    final unit = _code();
    if (unit == 0x2D || unit == 0x2B) {
      _at++;
    }
    while (_at < _text.length) {
      final digit = _text.codeUnitAt(_at);
      if (digit >= 0x30 && digit <= 0x39) {
        _at++;
        continue;
      }
      if (digit == 0x2E ||
          digit == 0x65 ||
          digit == 0x45 ||
          digit == 0x2D ||
          digit == 0x2B) {
        _at++;
        continue;
      }
      break;
    }
    final text = _text.substring(start, _at);
    if (text.isEmpty) throw const FormatException('number');
    return num.parse(text);
  }

  bool _readBool() {
    _skipWhitespace();
    if (_text.startsWith('true', _at)) {
      _at += 4;
      return true;
    }
    if (_text.startsWith('false', _at)) {
      _at += 5;
      return false;
    }
    throw const FormatException('bool');
  }

  List<String>? _readStringList() {
    _skipWhitespace();
    if (_code() == 0x6E) {
      _skipValue();
      return null;
    }
    if (_code() != 0x5B) throw const FormatException('list');
    _at++;
    final items = <String>[];
    _skipWhitespace();
    if (_code() == 0x5D) {
      _at++;
      return items;
    }
    while (true) {
      _skipWhitespace();
      items.add(_readString());
      _skipWhitespace();
      final next = _code();
      if (next == 0x5D) {
        _at++;
        return items;
      }
      if (next != 0x2C) throw const FormatException('item end');
      _at++;
    }
  }

  /// Advances past any JSON value at the cursor.
  void _skipValue() {
    _skipWhitespace();
    final unit = _code();
    if (unit == 0x22) {
      _skipString();
      return;
    }
    if (unit == 0x7B || unit == 0x5B) {
      _skipContainer();
      return;
    }
    while (_at < _text.length) {
      final digit = _text.codeUnitAt(_at);
      if (digit == 0x2C ||
          digit == 0x7D ||
          digit == 0x5D ||
          digit == 0x20 ||
          digit == 0x09 ||
          digit == 0x0A ||
          digit == 0x0D) {
        return;
      }
      _at++;
    }
  }

  void _skipContainer() {
    final open = _code();
    final close = open == 0x7B ? 0x7D : 0x5D;
    _at++;
    var depth = 1;
    while (depth > 0) {
      final unit = _code();
      if (unit == 0x22) {
        _skipString();
        continue;
      }
      if (unit == open) {
        depth++;
      } else if (unit == close) {
        depth--;
      }
      _at++;
    }
  }

  void _skipWhitespace() {
    final text = _text;
    var at = _at;
    while (at < text.length) {
      final unit = text.codeUnitAt(at);
      if (unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D) {
        at++;
      } else {
        break;
      }
    }
    _at = at;
  }
}
