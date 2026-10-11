import 'dart:io';

import 'package:fl_clash/common/constant.dart';
import 'package:test/test.dart';

/// The app and the core each keep a copy of the browser user agent and the default test URL.
void main() {
  test('the app and the core share one user agent and test URL', () {
    final dart = File('lib/common/constant.dart').readAsStringSync();
    final go = File('core/outbound_ip.go').readAsStringSync();
    final core = File('core/common.go').readAsStringSync();
    expect(_dartConst(dart, 'browserUa'), startsWith('Mozilla/5.0 '));
    expect(_dartConst(dart, 'defaultTestUrl'), startsWith('https://'));

    expect(
      _dartConst(dart, 'browserUa'),
      _goConst(go, 'browserUserAgent'),
      reason: 'browserUa and browserUserAgent must stay in step',
    );
    expect(
      _dartConst(dart, 'defaultTestUrl'),
      _goConst(core, 'defaultTestURL'),
      reason: 'defaultTestUrl and defaultTestURL must stay in step',
    );
  });

  test('the editor suggests the default test URL', () {
    final schema = File(
      'lib/features/editor/clash_schema.dart',
    ).readAsStringSync();
    final suggested = RegExp(
      r"'url': YamlSchema\.scalar\(\['([^']+)'\]\)",
    ).allMatches(schema).map((match) => match.group(1)).toList();

    expect(suggested, isNotEmpty);
    for (final url in suggested) {
      expect(url, defaultTestUrl, reason: 'the schema suggests $url');
    }
  });

  test('the app and the core agree on the service ids', () {
    final app = File('lib/common/service_probe.dart').readAsStringSync();
    final core = File('core/service_check.go').readAsStringSync();
    final targets = _enumValues(app, 'ServiceTarget', r"^\s{2}\w+\('([^']+)',");
    final statuses = _enumValues(
      app,
      'ServiceProbeStatus',
      r"^\s{2}\w+\('([^']+)'\)",
    );
    final registered = _quotedValues(core, r'\{name: "([^"]+)", check:');
    final reported = _quotedValues(core, r'service\w+\s*=\s*"([^"]+)"');

    expect(targets, isNotEmpty);
    expect(statuses, isNotEmpty);
    expect(registered, isNotEmpty);
    expect(reported, isNotEmpty);
    expect(
      targets,
      registered,
      reason: 'a ServiceTarget id must name a checker the core registers',
    );
    expect(
      statuses,
      reported,
      reason: 'a ServiceProbeStatus id must be a status the core reports',
    );
  });

  test('the app and the core agree on the method names', () {
    final app = File('lib/core/method.dart').readAsStringSync();
    final core = File('core/constant.go').readAsStringSync();
    final methods = _enumValues(app, 'CoreMethod', r'^  (\w+),');
    final dispatched = _quotedValues(
      core,
      r'^\s*\w+Method\s+CoreMethod\s*=\s*"([^"]+)"',
    );

    expect(methods, isNotEmpty);
    expect(dispatched, isNotEmpty);
    expect(
      methods,
      dispatched,
      reason: 'a CoreMethod name must be one the core answers',
    );
  });

  test('every core call sends the argument shape its handler decodes', () {
    final app = File('lib/core/interface.dart').readAsStringSync();
    final constants = File('core/constant.go').readAsStringSync();
    final core = File('core/method.go').readAsStringSync();
    final sent = _dartArgumentShapes(app);
    final decoded = _goArgumentShapes(core, constants);

    expect(sent, isNotEmpty, reason: 'the app calls a core method with args');
    expect(decoded, isNotEmpty, reason: 'the core decodes method args');
    final compared = sent.keys.where(decoded.containsKey).length;
    expect(
      compared,
      greaterThanOrEqualTo(20),
      reason: 'a broken extraction would leave nothing to compare',
    );
    final mismatched = <String>[];
    for (final entry in sent.entries) {
      final expected = decoded[entry.key];
      if (expected == null) {
        continue;
      }
      if (expected != entry.value) {
        mismatched.add(
          '${entry.key}: app sends ${entry.value}, core $expected',
        );
      }
    }
    expect(
      mismatched,
      isEmpty,
      reason:
          'a handler that unmarshals a string cannot read an object, and one '
          'that unmarshals a struct cannot read a string',
    );
  });

  test('the app and the core agree on the service sweep budget', () {
    final app = File('lib/common/constant.dart').readAsStringSync();
    final core = File('core/service_check.go').readAsStringSync();

    expect(
      _dartIntConst(app, 'serviceSweepBudgetFactor'),
      _goIntConst(core, 'serviceSweepBudgetFactor'),
      reason: 'the guard the app waits with must cover the sweep the core runs',
    );
  });

  test('the app and the helper agree on how they talk', () {
    final app = File('lib/common/constant.dart').readAsStringSync();
    final hub = File('services/helper/src/service/hub.rs').readAsStringSync();
    final linux = File(
      'services/helper/src/service/linux.rs',
    ).readAsStringSync();
    final windows = File(
      'services/helper/src/service/windows.rs',
    ).readAsStringSync();

    expect(
      _dartConst(app, 'helperProtocolVersionHeader'),
      _rustConst(hub, 'PROTOCOL_VERSION_HEADER'),
      reason: 'the app must send the header the helper reads',
    );
    expect(
      _dartConst(app, 'helperProtocolVersion'),
      _rustConst(hub, 'PROTOCOL_VERSION'),
      reason: 'a version the helper does not answer makes it unreachable',
    );
    expect(
      _dartIntConst(app, 'helperPort'),
      _rustIntConst(hub, 'LISTEN_PORT'),
      reason: 'the app dials the port the helper listens on',
    );
    expect(
      _dartConst(app, 'helperSocketPath'),
      _rustConst(linux, 'SOCKET_PATH'),
      reason: 'the app connects to the socket the helper owns',
    );
    expect(
      _dartConst(app, 'appHelperService'),
      _rustConst(windows, 'SERVICE_NAME'),
      reason: 'the app installs the service the helper registers',
    );
  });

  test('every message the core sends decodes into an app event', () {
    final app = File('lib/enum/enum.dart').readAsStringSync();
    final core = File('core/constant.go').readAsStringSync();
    final events = _enumValues(app, 'CoreEventType', r'^  (\w+),');
    final messages = _quotedValues(
      core,
      r'^\s*\w+Message\s+MessageType\s*=\s*"([^"]+)"',
    );

    expect(events, isNotEmpty);
    expect(messages, isNotEmpty);
    expect(
      messages.difference(events),
      isEmpty,
      reason:
          'a message the core sends must be a CoreEventType the app decodes',
    );
  });

  test('the app and the core agree on the geo resources', () {
    final app = File('lib/enum/enum.dart').readAsStringSync();
    final core = File('core/hub.go').readAsStringSync();
    // The body slice ends at the enum's `;`, so the last member arrives
    // without its separator and needs the end-of-input alternative.
    final names = _enumValues(app, 'GeoResource', r'^  (\w+)(?:[,;]|$)');
    final values = _enumValues(app, 'GeoResource', r"@JsonValue\('([^']+)'\)");
    final keys = _quotedValues(core, r'^\t"(\w+)":\s+\{update:');
    final lowerKeys = {for (final key in keys) key.toLowerCase()};

    expect(names, isNotEmpty);
    expect(values, isNotEmpty);
    expect(keys, isNotEmpty);
    expect(
      names,
      keys,
      reason:
          'the app updates a resource by name, which the core looks up as is',
    );
    expect(
      values,
      lowerKeys,
      reason:
          'the core reports the name back and the app decodes it lower cased',
    );
  });

  test('the app and the core agree on the geo update status', () {
    final core = File('core/constant.go').readAsStringSync();
    final event = File('lib/core/event.dart').readAsStringSync();
    final sent = _goJsonTags(core, 'GeoUpdateStatus');
    final read = _quotedValues(event, r"data\['([^']+)'\]");

    expect(sent, isNotEmpty);
    expect(read, isNotEmpty);
    expect(
      read.difference(sent),
      isEmpty,
      reason: 'a geo update event must carry the keys the app reads',
    );
  });

  test('every field the app reads from a core payload is one the core sends', () {
    // Renaming either side turns the field into its default without any error,
    // so the two halves are compared whenever one of them is edited.
    const pairs =
        <(String goFile, String goStruct, String dartFile, String dartClass)>[
          (
            'core/constant.go',
            'InitParams',
            'lib/models/core.dart',
            'InitParams',
          ),
          (
            'core/constant.go',
            'SetupParams',
            'lib/models/core.dart',
            'SetupParams',
          ),
          (
            'core/constant.go',
            'UpdateParams',
            'lib/models/core.dart',
            'UpdateParams',
          ),
          (
            'core/constant.go',
            'tunSchema',
            'lib/models/clash_config.dart',
            'Tun',
          ),
          (
            'core/constant.go',
            'ChangeProxyParams',
            'lib/models/core.dart',
            'ChangeProxyParams',
          ),
          (
            'core/constant.go',
            'ChangeProxyResult',
            'lib/models/core.dart',
            'ChangeProxyResult',
          ),
          (
            'core/constant.go',
            'RouteState',
            'lib/models/core.dart',
            'RouteSnapshot',
          ),
          (
            'core/constant.go',
            'ProbeParams',
            'lib/models/core.dart',
            'ProbeParams',
          ),
          (
            'core/constant.go',
            'ProbeResult',
            'lib/models/core.dart',
            'ProbeResult',
          ),
          (
            'core/constant.go',
            'ProxiesData',
            'lib/models/core.dart',
            'ProxiesData',
          ),
          ('core/constant.go', 'Delay', 'lib/models/core.dart', 'Delay'),
          (
            'core/constant.go',
            'MemoryStats',
            'lib/models/core.dart',
            'CoreMemoryStats',
          ),
          (
            'core/constant.go',
            'ExternalProvider',
            'lib/models/core.dart',
            'ExternalProvider',
          ),
          (
            'core/outbound_ip.go',
            'OutboundIpParams',
            'lib/models/core.dart',
            'OutboundIpParams',
          ),
          (
            'core/outbound_ip.go',
            'OutboundIpResult',
            'lib/models/core.dart',
            'OutboundIpResult',
          ),
          (
            'core/service_check.go',
            'ServiceCheckParams',
            'lib/models/core.dart',
            'ServiceCheckParams',
          ),
          (
            'core/service_check.go',
            'ServiceCheckItem',
            'lib/models/core.dart',
            'ServiceCheckItem',
          ),
          (
            'core/dns_query.go',
            'DnsQuery',
            'lib/models/common.dart',
            'DnsQuery',
          ),
        ];
    final sources = <String, String>{};
    for (final (goFile, _, dartFile, _) in pairs) {
      sources[goFile] ??= File(goFile).readAsStringSync();
      sources[dartFile] ??= File(dartFile).readAsStringSync();
    }

    for (final (goFile, goStruct, dartFile, dartClass) in pairs) {
      final sent = _goJsonTags(sources[goFile]!, goStruct);
      final read = _dartJsonNames(sources[dartFile]!, dartClass);
      expect(sent, isNotEmpty, reason: '$goStruct must send something');
      expect(read, isNotEmpty, reason: '$dartClass must read something');
      final missing = read
          .where((name) => !sent.contains(name) && !sent.contains(_kebab(name)))
          .toSet();
      expect(
        missing,
        isEmpty,
        reason:
            '$dartClass reads ${missing.join(', ')}, which $goStruct does not '
            'send ($sent)',
      );
    }
  });

  test('the app and the core agree on the service checker names', () {
    final app = File('lib/common/service_probe.dart').readAsStringSync();
    final core = File('core/service_check.go').readAsStringSync();
    final targets = _enumValues(app, 'ServiceTarget', r"^\s+\w+\('([^']+)'");
    final registered = RegExp(
      r'\{name: "([^"]+)"',
    ).allMatches(core).map((match) => match.group(1)!).toSet();

    expect(targets, isNotEmpty, reason: 'ServiceTarget must name its checks');
    expect(registered, isNotEmpty, reason: 'the core must register checks');
    expect(
      targets,
      registered,
      reason: 'a target the core does not register can only ever fail',
    );
  });

  test('every dns and ntp override names a key the core reads', () {
    final app = File('lib/enum/enum.dart').readAsStringSync();
    final core = File('core/Clash.Meta/config/config.go').readAsStringSync();
    final dnsKeys = _dartEnumPaths(app, 'DnsOverrideKey');
    final ntpKeys = _dartEnumPaths(app, 'NtpOverrideKey');
    final coreDns = _goYamlTags(core, 'RawDNS');
    final coreNtp = _goYamlTags(core, 'RawNTP');
    final coreFallbackFilter = _goYamlTags(core, 'RawFallbackFilter');
    const fallbackFilterPrefix = 'fallback-filter.';

    expect(dnsKeys, isNotEmpty, reason: 'reading DnsOverrideKey broke');
    expect(ntpKeys, isNotEmpty, reason: 'reading NtpOverrideKey broke');
    expect(
      dnsKeys
          .where((key) => !key.startsWith(fallbackFilterPrefix))
          .toSet()
          .difference(coreDns),
      isEmpty,
      reason:
          'A dns override the core does not read silently does nothing. '
          'The core reads: $coreDns',
    );
    expect(
      dnsKeys
          .where((key) => key.startsWith(fallbackFilterPrefix))
          .map((key) => key.substring(fallbackFilterPrefix.length))
          .toSet()
          .difference(coreFallbackFilter),
      isEmpty,
      reason:
          'A fallback filter the core does not read silently does nothing. '
          'The core reads: $coreFallbackFilter',
    );
    expect(
      ntpKeys.difference(coreNtp),
      isEmpty,
      reason:
          'An ntp override the core does not read silently does nothing. '
          'The core reads: $coreNtp',
    );
  });

  test('the app and the core agree on the maps it builds by hand', () {
    final app = File('lib/core/interface.dart').readAsStringSync();
    final core = File('core/constant.go').readAsStringSync();
    // These payloads have no model on the app side: it builds the request map
    // and reads the response keys by hand, so nothing else compares them.
    final cases =
        <(String what, Set<String> keys, String goStruct, bool exact)>[
          (
            'the delay test request',
            _dartMapLiteralKeys(app, 'delayParams'),
            'TestDelayParams',
            true,
          ),
          (
            'the proxy query',
            _dartKeyedValues(_callSection(app, 'getProxies')),
            'ProxiesQuery',
            true,
          ),
          (
            'the side loaded provider',
            _dartKeyedValues(_callSection(app, 'sideLoadExternalProvider')),
            'SideLoadParams',
            true,
          ),
          (
            'the proxy snapshot',
            _dartBracketKeys(_callSection(app, 'getProxies')),
            'ProxiesData',
            false,
          ),
          (
            'the traffic stats',
            _dartBracketKeys(_callSection(app, 'getTrafficStats')),
            'TrafficStats',
            false,
          ),
        ];
    for (final (what, keys, goStruct, exact) in cases) {
      final sent = _goJsonTags(core, goStruct);
      expect(keys, isNotEmpty, reason: '$what must send or read something');
      expect(
        keys.difference(sent),
        isEmpty,
        reason:
            '$what names ${keys.difference(sent).join(', ')}, which $goStruct does not carry',
      );
      if (!exact) {
        // A response key the app leaves to a model is pinned by the payload
        // check instead of here.
        continue;
      }
      expect(
        sent.difference(keys),
        isEmpty,
        reason:
            '$goStruct carries ${sent.difference(keys).join(', ')}, which $what never names',
      );
    }
  });
}

String _kebab(String name) => name
    .replaceAllMapped(
      RegExp('[A-Z]'),
      (match) => '-${match.group(0)!.toLowerCase()}',
    )
    .replaceFirst(RegExp('^-'), '');

/// The keys of a `final <name> = { ... };` map the app builds for one call.
Set<String> _dartMapLiteralKeys(String source, String name) {
  final start = source.indexOf('final $name = {');
  if (start < 0) {
    fail('could not find the $name map in the app sources');
  }
  final end = source.indexOf('};', start);
  if (end < 0) {
    fail('could not find the end of the $name map');
  }
  return _dartKeyedValues(source.substring(start, end));
}

/// The keys of the map literals inside one `CoreMethod` call.
Set<String> _dartKeyedValues(String call) => _quotedValues(call, r"'([^']+)':");

/// The keys the app reads off the payload of one `CoreMethod` call.
Set<String> _dartBracketKeys(String call) =>
    _quotedValues(call, r"data\['([^']+)'\]");

/// The text of one call, from its method name up to the next call.
String _callSection(String source, String method) {
  final start = source.indexOf('method: CoreMethod.$method');
  if (start < 0) {
    fail('could not find the $method call in the app sources');
  }
  final next = source.indexOf('method: CoreMethod.', start + 1);
  return source.substring(start, next < 0 ? source.length : next);
}

/// The methods the app calls, with the shape of the argument it sends: an
/// object (a `toJson()` map or a collection held in a local) or a scalar.
Map<String, String> _dartArgumentShapes(String source) {
  final structured = _quotedValues(
    source,
    r'(?:List|Map|Set)<[^\n]*?>\s+(\w+)',
  ).union(_quotedValues(source, r'final (\w+) = [<\w, >]*[\{\[]'));
  final shapes = <String, String>{};
  for (final match in RegExp(
    r'method: CoreMethod\.(\w+),\s*arguments: ([^\n]+)',
  ).allMatches(source)) {
    final expression = match.group(2)!.trim().replaceFirst(RegExp(r',$'), '');
    shapes[match.group(1)!] = _isObjectArgument(expression, structured)
        ? 'object'
        : 'scalar';
  }
  return shapes;
}

bool _isObjectArgument(String expression, Set<String> structured) {
  if (expression.startsWith('{') || expression.startsWith('<')) {
    return true;
  }
  return expression.contains('.toJson()') || structured.contains(expression);
}

/// The methods the core answers with arguments, with the shape their handler
/// unmarshals the payload into.
Map<String, String> _goArgumentShapes(String source, String constants) {
  const scalars = {
    'string',
    'bool',
    'int',
    'int8',
    'int16',
    'int32',
    'int64',
    'uint',
    'uint8',
    'uint16',
    'uint32',
    'uint64',
    'float32',
    'float64',
  };
  final names = <String, String>{};
  for (final match in RegExp(
    r'^\s*(\w+Method)\s+CoreMethod\s*=\s*"([^"]+)"',
    multiLine: true,
  ).allMatches(constants)) {
    names[match.group(1)!] = match.group(2)!;
  }
  final shapes = <String, String>{};
  // Each handler entry ends where the next one starts, so a handler that takes
  // no arguments cannot pick up the parameter type of the entry after it.
  final entries = RegExp(
    r'^\t(\w+Method):',
    multiLine: true,
  ).allMatches(source).toList();
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    final name = entry.group(1)!;
    final method = names[name];
    if (method == null) {
      fail('could not read $name from the core sources');
    }
    final end = index + 1 < entries.length ? entries[index + 1].start : null;
    final body = source.substring(entry.end, end);
    final parameter = RegExp(
      r'func\((\w+)\s+\*([^\s,]+)\s*,\s*response\b',
    ).firstMatch(body);
    if (parameter == null) {
      continue;
    }
    final type = parameter.group(2)!;
    if (type != 'MethodCall') {
      shapes[method] = _isScalarType(type, scalars) ? 'scalar' : 'object';
      continue;
    }
    // A raw handler decodes one variable of its own.
    final variable = RegExp(
      r'var (\w+) (\w+)[\s\S]*?decodeMethodArguments\(call, response, &(\w+)\)',
    ).firstMatch(body);
    if (variable == null) {
      continue;
    }
    if (variable.group(1) != variable.group(3)) {
      fail('$name decodes ${variable.group(3)}, not ${variable.group(1)}');
    }
    shapes[method] = _isScalarType(variable.group(2)!, scalars)
        ? 'scalar'
        : 'object';
  }
  return shapes;
}

bool _isScalarType(String type, Set<String> scalars) =>
    scalars.contains(type.replaceFirst(RegExp(r'^\[\]'), ''));

/// The names the fields of a Go struct are encoded under.
Set<String> _goJsonTags(String source, String name) {
  final start = source.indexOf('type $name struct {');
  if (start < 0) {
    fail('could not find struct $name in the core sources');
  }
  final end = source.indexOf('\n}', start);
  if (end < 0) {
    fail('could not find the end of struct $name');
  }
  return _quotedValues(
    source.substring(start, end),
    r'^\s*[A-Z]\w*\s+.*json:"([^",`]+)',
  );
}

/// The keys a freezed factory of the app reads, taking the `@JsonKey` name when
/// one is given and the field name otherwise.
Set<String> _dartJsonNames(String source, String className) {
  const header = 'const factory ';
  final open = source.indexOf('$header$className({');
  if (open < 0) {
    fail('could not find the $className factory in the app sources');
  }
  final close = source.indexOf('}) =', open);
  if (close < 0) {
    fail('could not find the end of the $className factory');
  }
  final names = <String>{};
  for (final chunk in _splitTopLevel(
    source.substring(open + header.length + className.length + 2, close),
  )) {
    final parameter = chunk.trim();
    if (parameter.isEmpty) {
      continue;
    }
    final keyed = RegExp("name: '([^']+)'").firstMatch(parameter);
    if (keyed != null) {
      names.add(keyed.group(1)!);
      continue;
    }
    final field = RegExp(
      r'([A-Za-z_]\w*)\s*\??\s*$',
    ).firstMatch(parameter.replaceAll(RegExp(r'=\s*.+$', dotAll: true), ''));
    if (field == null) {
      fail('could not read a field name from "$parameter"');
    }
    names.add(field.group(1)!);
  }
  return names;
}

List<String> _splitTopLevel(String body) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  for (var index = 0; index < body.length; index++) {
    final char = body[index];
    if (char == '<' || char == '(' || char == '[') {
      depth++;
    } else if (char == '>' || char == ')' || char == ']') {
      depth--;
    } else if (char == ',' && depth == 0) {
      parts.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  parts.add(buffer.toString());
  return parts;
}

String _rustConst(String source, String name) {
  final match = RegExp('const $name: &str = "([^"]+)"').firstMatch(source);
  if (match == null) {
    fail('could not read $name from the helper sources');
  }
  return match.group(1)!;
}

int _rustIntConst(String source, String name) {
  final match = RegExp('const $name: u16 = (\\d+)').firstMatch(source);
  if (match == null) {
    fail('could not read $name from the helper sources');
  }
  return int.parse(match.group(1)!);
}

int _dartIntConst(String source, String name) {
  final match = RegExp('const $name\\s*=\\s*(\\d+)').firstMatch(source);
  if (match == null) {
    fail('could not read $name from the Dart constants');
  }
  return int.parse(match.group(1)!);
}

int _goIntConst(String source, String name) {
  final match = RegExp('$name\\s*=\\s*(\\d+)').firstMatch(source);
  if (match == null) {
    fail('could not read $name from the core sources');
  }
  return int.parse(match.group(1)!);
}

Set<String> _enumValues(String source, String name, String pattern) {
  final start = source.indexOf('enum $name {');
  if (start < 0) {
    fail('could not find enum $name in the app sources');
  }
  final semi = source.indexOf(';', start);
  final close = source.indexOf('}', start);
  final end = semi > start && semi < close ? semi : close;
  return _quotedValues(source.substring(start, end), pattern);
}

Set<String> _quotedValues(String source, String pattern) {
  return RegExp(
    pattern,
    multiLine: true,
  ).allMatches(source).map((match) => match.group(1)!).toSet();
}

Set<String> _dartEnumPaths(String source, String name) {
  final body = RegExp(
    'enum $name \\{(.*?)\\n\\}',
    dotAll: true,
  ).firstMatch(source);
  if (body == null) {
    fail('could not read enum $name from the app sources');
  }
  return RegExp(
    r"^\s+\w+\('([^']+)'\)",
    multiLine: true,
  ).allMatches(body.group(1)!).map((match) => match.group(1)!).toSet();
}

Set<String> _goYamlTags(String source, String structName) {
  final body = RegExp(
    'type $structName struct \\{(.*?)\\n\\}',
    dotAll: true,
  ).firstMatch(source);
  if (body == null) {
    fail('could not read struct $structName from the core sources');
  }
  return RegExp(
    r'yaml:"([^",]+)',
  ).allMatches(body.group(1)!).map((match) => match.group(1)!).toSet();
}

String _dartConst(String source, String name) {
  final match = RegExp("const $name\\s*=\\s*'([^']+)'").firstMatch(source);
  if (match == null) {
    fail('could not read $name from the Dart constants');
  }
  return match.group(1)!;
}

String _goConst(String source, String name) {
  final match = RegExp('$name\\s*=\\s*"([^"]+)"').firstMatch(source);
  if (match == null) {
    fail('could not read $name from the core sources');
  }
  return match.group(1)!;
}
