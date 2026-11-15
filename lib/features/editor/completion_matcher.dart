import 'package:code_forge/code_forge.dart'
    show CodeForgeCompletion, CodeForgeSuggestion;

const _maxSuggestions = 60;

/// A prefix beats a segment prefix, which beats the letters in order.
/// [lowerTyped] is [typed] already lowercased, so a whole ranking pass pays
/// for the transform once instead of once per candidate.
int? completionScore(String candidate, String typed, String lowerTyped) {
  if (typed.isEmpty) {
    return 0;
  }
  final lower = candidate.toLowerCase();
  if (lower.startsWith(lowerTyped)) {
    return 3000 - candidate.length + (candidate.startsWith(typed) ? 100 : 0);
  }
  // A segment prefix can only begin where the typed text occurs, so the
  // substring search finds those places and the segment probe only runs on
  // them. A candidate that never contains the typed text skips the probe
  // entirely, which is what a large word table pays for on every keystroke.
  var at = lower.indexOf(lowerTyped, 1);
  while (at > 0) {
    if (_startsSegment(candidate, at)) {
      return 2000 - at - candidate.length;
    }
    at = lower.indexOf(lowerTyped, at + 1);
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

bool _startsSegment(String text, int index) {
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

List<CodeForgeSuggestion> rankSuggestions(
  String typed,
  Iterable<CodeForgeSuggestion> candidates,
) {
  final seen = <String>{};
  final lowerTyped = typed.toLowerCase();
  final scored = <(int, int, CodeForgeSuggestion)>[];
  var index = 0;
  for (final candidate in candidates) {
    final label = candidate.label;
    if (!seen.add(label) || (label == typed && candidate.snippet == null)) {
      continue;
    }
    final score = completionScore(label, typed, lowerTyped);
    if (score != null) {
      scored.add((score, index++, candidate));
    }
  }
  scored.sort((a, b) {
    final byScore = b.$1.compareTo(a.$1);
    return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
  });
  return [
    for (final (_, _, suggestion) in scored.take(_maxSuggestions)) suggestion,
  ];
}

CodeForgeCompletion? completeFrom(
  String typed,
  Iterable<CodeForgeSuggestion> candidates,
) {
  if (typed.isEmpty) {
    return null;
  }
  return CodeForgeCompletion(
    prefix: typed,
    suggestions: rankSuggestions(typed, candidates),
  );
}
