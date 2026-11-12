@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/ui/emoji.dart';
import 'package:flutter_test/flutter_test.dart';

// The raw RegExp the memoizing pattern stands in for, kept here so a run can
// price both in the same process.
final _raw = RegExp(
  // ignore: valid_regexps
  r'\p{RI}\p{RI}'
  r'|[#*0-9]️?⃣'
  r'|\p{Emoji}(?<![#*0-9])'
  r'(?:\p{EMod}|️⃣?|[\u{E0020}-\u{E007E}]+\u{E007F})?'
  r'(?:‍\p{Emoji}(?:\p{EMod}|️⃣?|[\u{E0020}-\u{E007E}]+\u{E007F})?)*',
  unicode: true,
);

void main() {
  test('a group name scans for emoji for what it costs', () {
    const names = [
      'Proxy',
      'Auto',
      'Fallback',
      'US Los Angeles 01',
      '手动选择',
      'Hong Kong 03 \u{1F1ED}\u{1F1F0}',
      '1倍率 ',
      'DIRECT',
    ];
    const attempts = 50000;
    var raw = 0;
    var memo = 0;
    for (final name in names) {
      raw += _raw.allMatches(name).length;
      memo += emojiPattern.allMatches(name).length;
    }
    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final name in names) {
        raw += _raw.allMatches(name).length;
      }
    }
    final rawNs =
        stopwatch.elapsedMicroseconds * 1000 / attempts / names.length;
    stopwatch.reset();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final name in names) {
        memo += emojiPattern.allMatches(name).length;
      }
    }
    stopwatch.stop();
    final memoNs =
        stopwatch.elapsedMicroseconds * 1000 / attempts / names.length;
    stdout.writeln(
      'emojiScan names=${names.length} attempts=$attempts '
      'rawPerNameNs=$rawNs memoPerNameNs=$memoNs verdict=${raw + memo}',
    );
  });
}
