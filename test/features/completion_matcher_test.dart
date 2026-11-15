import 'package:code_forge/code_forge.dart' show CodeForgeSuggestion;
import 'package:fl_clash/features/editor/completion_matcher.dart'
    show completeFrom, completionScore;
import 'package:flutter_test/flutter_test.dart';

List<String> _labelsOf(String typed, List<String> candidates) {
  final completion = completeFrom(typed, [
    for (final label in candidates) CodeForgeSuggestion(label: label),
  ]);
  return [
    for (final suggestion in completion?.suggestions ?? const [])
      suggestion.label,
  ];
}

void main() {
  test('a prefix outranks a segment prefix and that an in-order match', () {
    expect(_labelsOf('pool', ['politics', 'proxy-policy', 'path-pool']), [
      'path-pool',
      'proxy-policy',
    ]);
  });

  test('folds case on both sides of the comparison', () {
    expect(_labelsOf('pool', ['Pool', 'POOL', 'ApPle', 'pol']), [
      'Pool',
      'POOL',
    ]);
  });

  test('drops an exact duplicate label and offers nothing twice', () {
    expect(_labelsOf('pool', ['path-pool', 'path-pool']), ['path-pool']);
  });

  test('an empty prefix offers no completion', () {
    expect(
      completeFrom('', const [CodeForgeSuggestion(label: 'pool')]),
      isNull,
    );
  });

  test('scores every candidate the way a position scan used to', () {
    final lowerTyped = 'po'.toLowerCase();
    for (final candidate in _segmentCandidates) {
      expect(
        completionScore(candidate, 'po', lowerTyped),
        _scannedScore(candidate, 'po', lowerTyped),
        reason: 'candidate "$candidate"',
      );
    }
  });

  test('scores every candidate the way a position scan used to, over a wide '
      'set of prefixes', () {
    for (final typed in _typedSamples) {
      final lowerTyped = typed.toLowerCase();
      for (final candidate in _segmentCandidates) {
        expect(
          completionScore(candidate, typed, lowerTyped),
          _scannedScore(candidate, typed, lowerTyped),
          reason: 'candidate "$candidate" typed "$typed"',
        );
      }
    }
  });
}

/// The shape the matcher had before the substring search moved in front of
/// the segment probe: every position is probed and the first segment start
/// whose text matches wins.
int? _scannedScore(String candidate, String typed, String lowerTyped) {
  if (typed.isEmpty) {
    return 0;
  }
  final lower = candidate.toLowerCase();
  if (lower.startsWith(lowerTyped)) {
    return 3000 - candidate.length + (candidate.startsWith(typed) ? 100 : 0);
  }
  for (var i = 1; i < candidate.length; i++) {
    if (_scannedStartsSegment(candidate, i) &&
        lower.startsWith(lowerTyped, i)) {
      return 2000 - i - candidate.length;
    }
  }
  if (lower.isEmpty || lower[0] != lowerTyped[0]) {
    return null;
  }
  var matched = 1;
  for (var i = 1; i < lower.length && matched < lowerTyped.length; i++) {
    if (lower[i] == lowerTyped[matched]) {
      matched++;
    }
  }
  return matched == lowerTyped.length ? 1000 - candidate.length : null;
}

bool _scannedStartsSegment(String text, int index) {
  final previous = text[index - 1];
  if (previous == '-' || previous == '_' || previous == '.') {
    return true;
  }
  final current = text[index];
  return previous.toLowerCase() == previous &&
      previous.toUpperCase() != previous &&
      current.toUpperCase() == current &&
      current.toLowerCase() != current;
}

const _typedSamples = <String>[
  '',
  'p',
  'po',
  'prox',
  'proxy',
  'proxy-',
  'proxy-g',
  'd',
  'in',
  'u',
  'node',
  'tokyo',
  'ünï',
  '中文',
  '中',
  '😀',
  'e',
  '1',
  '12',
  'gr',
  ' ',
  'ab',
  'abcdef',
  'zzz',
];

const _segmentCandidates = <String>[
  'TokyoNode',
  'SingaporeRelay',
  'LosAngelesDirect',
  'proxy-groups',
  'PROXY-GROUPS',
  'Proxy_Groups',
  'proxy.groups',
  'proxyGroups',
  'proxy groups',
  'a-b-c',
  'ABCDef',
  'aBCDef',
  'ünïcode-Node',
  'ÜnïcodeNode',
  'Ünïcode-node',
  '中文节点',
  '中文-节点',
  'emoji😀Node',
  '😀Node',
  '1234',
  '-leading',
  '_leading',
  '.leading',
  'trailing-',
  'MiXeD CaSe',
  'ALLCAPS',
  'allcaps',
];
