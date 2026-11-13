import 'package:code_forge/code_forge.dart' show CodeForgeSuggestion;
import 'package:fl_clash/features/editor/completion_matcher.dart'
    show completeFrom;
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
}
