@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/ui/emoji.dart';
import 'package:flutter_test/flutter_test.dart';

final _raw = RegExp(
  // ignore: valid_regexps
  r'\p{RI}\p{RI}'
  r'|[#*0-9]️?⃣'
  r'|\p{Emoji}(?<![#*0-9])'
  r'(?:\p{EMod}|️⃣?|[\u{E0020}-\u{E007E}]+\u{E007F})?'
  r'(?:‍\p{Emoji}(?:\p{EMod}|️⃣?|[\u{E0020}-\u{E007E}]+\u{E007F})?)*',
  unicode: true,
);

/// The shape a rebuild of one proxy row pays: the emoji scan, then the span
/// tree it builds from the matches.
int _scansOf(Pattern pattern, String text) {
  var count = 0;
  for (final _ in pattern.allMatches(text)) {
    count++;
  }
  return count;
}

void main() {
  test('rebuilding one row of proxy names pays what the scan costs', () {
    const rows = 40;
    const attempts = 5000;
    final names = [
      for (var index = 0; index < rows; index++)
        'HK-Node-${(index + 1).toString().padLeft(2, '0')}-Relay',
    ];
    var total = 0;
    for (final name in names) {
      total += _scansOf(_raw, name) + _scansOf(emojiPattern, name);
    }
    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final name in names) {
        total += _scansOf(_raw, name);
      }
    }
    final rawUs = stopwatch.elapsedMicroseconds / attempts;
    stopwatch.reset();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final name in names) {
        total += _scansOf(emojiPattern, name);
      }
    }
    stopwatch.stop();
    final memoUs = stopwatch.elapsedMicroseconds / attempts;
    stdout.writeln(
      'emojiRows rows=$rows attempts=$attempts rawRowUs=$rawUs '
      'memoRowUs=$memoUs verdict=$total',
    );
  });
}
