@Skip('Manual performance benchmark')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/event_json.dart';
import 'package:flutter_test/flutter_test.dart';

String _rowJson(int index) {
  return '{"id":"$index","metadata":{"uid":10123,"network":"tcp",'
      '"sourceIP":"10.0.0.1","sourcePort":"54321",'
      '"destinationIP":"203.0.113.7","destinationPort":"443",'
      '"host":"example-$index.test","process":"com.android.chrome",'
      '"processPath":"/data/app/chrome","remoteDestination":"198.51.100.2:443",'
      '"sourceGeoIP":["LAN","CN"],"destinationGeoIP":["US"],'
      '"destinationIPASN":"AS15133 Google LLC","sourceIPASN":"AS4134",'
      '"specialRules":"","specialProxy":"","mitm":false,"mitmRefused":false},'
      '"upload":${(index + 1) * 1024},"download":${(index + 1) * 4096},'
      '"start":${1730000000 + index},"chains":["Proxy","DIRECT"],'
      '"rule":"DOMAIN-SUFFIX","rulePayload":"test","downloadSpeed":$index,'
      '"uploadSpeed":$index}';
}

void main() {
  test('parses a connections snapshot frame within the budget', () {
    const rows = 500;
    const frames = 500;
    final eventsJson = [
      for (var index = 0; index < rows; index++)
        '{"type":"request","data":${_rowJson(index)}}',
    ].join(',');
    final payload = '{"id":"0","method":"message","arguments":[$eventsJson]}';
    final frame = utf8.encode(payload);

    final events = messageBatchFromFrame(frame);
    expect(events?.length, rows);

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < frames; attempt++) {
      if (messageBatchFromFrame(frame)?.length != rows) {
        fail('short snapshot frame');
      }
    }
    stopwatch.stop();
    final perFrameUs = stopwatch.elapsedMicroseconds / frames;
    stdout.writeln('rowParse rows=$rows frames=$frames perFrameUs=$perFrameUs');
    expect(perFrameUs, lessThan(20000));
  });
}
