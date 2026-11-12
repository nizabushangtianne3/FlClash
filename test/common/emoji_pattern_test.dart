library;

import 'package:fl_clash/ui/emoji.dart';
import 'package:flutter_test/flutter_test.dart';

// The raw RegExp the memoizing pattern replaces, so both can be compared
// case by case.
final _raw = RegExp(
  // ignore: valid_regexps
  r'\p{RI}\p{RI}'
  r'|[#*0-9]️?⃣'
  r'|\p{Emoji}(?<![#*0-9])'
  r'(?:\p{EMod}|️⃣?|[\u{E0020}-\u{E007E}]+\u{E007F})?'
  r'(?:‍\p{Emoji}(?:\p{EMod}|️⃣?|[\u{E0020}-\u{E007E}]+\u{E007F})?)*',
  unicode: true,
);

List<String> _slicesOf(Iterable<Match> matches) => [
  for (final match in matches) '${match.start}:${match.group(0)}',
];

void main() {
  group('emojiPattern', () {
    for (final text in const [
      '',
      ' ',
      'Proxy',
      'Auto',
      'Fallback',
      'US Los Angeles 01',
      '手动选择',
      'Hong Kong 03 \u{1F1ED}\u{1F1F0}',
      '1倍率 ',
      'keycap \uFE0F\u20E3',
      'skin \u{1F44D}\u{1F3FB}',
      'family \u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466} done',
      'tags \u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F} end',
      'a#b',
      '#',
      '\u{1F600}\u{1F601}\u{1F602}',
      'mixed 🚀 and \u6F22\u5B57 and \u{1F1E8}\u{1F1F3}',
    ]) {
      test('reports the same slices as the raw regexp for "$text"', () {
        expect(
          _slicesOf(emojiPattern.allMatches(text)),
          _slicesOf(_raw.allMatches(text)),
        );
      });
    }

    test('a match reports the slice it covers and nothing beyond it', () {
      final match = emojiPattern.allMatches('HK \u{1F1ED}\u{1F1F0}').first;
      expect(match.start, 3);
      expect(match.end, match.start + match.group(0)!.length);
      expect(match.group(0), match.input.substring(match.start, match.end));
      expect(match.groupCount, 0);
      expect(match[1], isNull);
      expect(match.group(1), '');
      expect(match.groups([0, 1]), [match.group(0), null]);
    });

    test('matchAsPrefix answers like the regexp it stands in for', () {
      for (final text in const ['Proxy', '\u{1F600} after', '#x', 'a#b']) {
        expect(
          emojiPattern.matchAsPrefix(text)?.group(0),
          _raw.matchAsPrefix(text)?.group(0),
        );
      }
      // matchAsPrefix anchors at its start index, so the raw regexp sees
      // nothing in a text that opens with plain text. The one call site scans
      // with allMatches, which does not have that anchor.
      expect(
        emojiPattern.matchAsPrefix('after \u{1F600}')?.group(0),
        '\u{1F600}',
      );
    });

    test('allMatches honours a start index only from a match boundary', () {
      const text = '\u{1F600} a \u{1F601} b \u{1F602}';
      expect(_slicesOf(emojiPattern.allMatches(text, 5)), ['5:😁', '10:😂']);
    });

    test('a cached scan keeps its answer', () {
      const text = 'Another \u{1F600} name';
      emojiPattern.allMatches(text);
      expect(
        _slicesOf(emojiPattern.allMatches(text)),
        _slicesOf(emojiPattern.allMatches(text)),
      );
    });

    test('the cache stays bounded', () {
      for (var index = 0; index < 500; index++) {
        emojiPattern.allMatches('name \u{1F600} $index');
      }
      expect(
        _slicesOf(emojiPattern.allMatches('name \u{1F600} 0')),
        _slicesOf(_raw.allMatches('name \u{1F600} 0')),
      );
    });
  });
}
