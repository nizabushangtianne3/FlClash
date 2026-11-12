/// Emoji in a string: flags, keycaps, and pictographs with their modifiers,
/// presentation selectors, tags and joined parts.
final _emojiRegExp = RegExp(
  // ignore: valid_regexps
  r'\p{RI}\p{RI}'
  r'|[#*0-9]️?⃣'
  r'|\p{Emoji}(?<![#*0-9])'
  r'(?:\p{EMod}|️⃣?|[\u{E0020}-\u{E007E}]+\u{E007F})?'
  r'(?:‍\p{Emoji}(?:\p{EMod}|️⃣?|[\u{E0020}-\u{E007E}]+\u{E007F})?)*',
  unicode: true,
);

const _emojiScanCacheLimit = 4096;

/// A text's emoji ranges depend on the text alone, and a proxy list rebuilds
/// the same names frame after frame, so each scan remembers its answer:
/// [EmojiText] walks the pattern once per distinct string instead of once per
/// build. Bounded like [_emojiScanCacheLimit] says, oldest entry first.
final class MemoizedEmojiPattern implements Pattern {
  final _scans = <String, List<({int start, int end})>>{};

  @override
  Iterable<Match> allMatches(String string, [int start = 0]) sync* {
    for (final range in _rangesOf(string)) {
      if (range.start < start) continue;
      yield _MatchAt(string, range.start, range.end);
    }
  }

  @override
  Match? matchAsPrefix(String string, [int start = 0]) {
    for (final range in _rangesOf(string)) {
      if (range.start < start) continue;
      return _MatchAt(string, range.start, range.end);
    }
    return null;
  }

  List<({int start, int end})> _rangesOf(String string) {
    final cached = _scans[string];
    if (cached != null) {
      return cached;
    }
    final ranges = [
      for (final match in _emojiRegExp.allMatches(string))
        (start: match.start, end: match.end),
    ];
    if (_scans.length >= _emojiScanCacheLimit) {
      _scans.remove(_scans.keys.first);
    }
    return _scans[string] = ranges;
  }
}

/// The slice one match covers, read without holding the match's own subtree.
final class _MatchAt implements Match {
  const _MatchAt(this.input, this.start, this.end);

  @override
  final String input;

  @override
  final int start;

  @override
  final int end;

  @override
  Pattern get pattern => _emojiRegExp;

  @override
  int get groupCount => 0;

  @override
  String? operator [](int group) {
    return group == 0 ? input.substring(start, end) : null;
  }

  @override
  String group(int group) => this[group] ?? '';

  @override
  List<String?> groups(List<int> groups) => [
    for (final group in groups) this[group],
  ];
}

/// What [EmojiText] scans with; the pattern remembers what each string costs.
final emojiPattern = MemoizedEmojiPattern();
