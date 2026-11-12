@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an icon src tells whether it is svg for what it costs', () {
    const srcs = [
      'https://cdn.example.com/icons/group-01.png?v=3',
      'data:image/svg+xml;base64,PHN2Zy8+',
      'https://cdn.example.com/assets/logo.fixed.svg',
      'https://cdn.example.com/a/b/c/d/e/f/chain-host-1234-5678.png',
      'data:image/png;base64,iVBORw0KGgo=',
    ];
    const attempts = 200000;
    var total = 0;
    for (final src in srcs) {
      total += src.isSvg ? 1 : 0;
    }
    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final src in srcs) {
        total += src.isSvg ? 1 : 0;
      }
    }
    stopwatch.stop();
    final perReadNs =
        stopwatch.elapsedMicroseconds * 1000 / attempts / srcs.length;
    stdout.writeln(
      'iconIsSvg srcs=${srcs.length} attempts=$attempts '
      'perReadNs=$perReadNs verdict=$total',
    );
  });
}
