import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _sources = [
  'lib/features/editor/clash_completion.dart',
  'lib/features/editor/script_completion.dart',
  'plugins/code_forge/lib/code_forge/controller/editing.dart',
  'plugins/code_forge/lib/code_forge/controller/navigation.dart',
  'plugins/code_forge/lib/code_forge/controller/edit_pipeline.dart',
  'plugins/code_forge/lib/code_forge/controller/snippet.dart',
];

void main() {
  test('editor hot-path regexes are compiled once', () {
    for (final path in _sources) {
      final lines = File(path).readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        if (!line.contains('RegExp(')) continue;
        final trimmed = line.trimLeft();
        expect(
          trimmed.startsWith('final ') || trimmed.startsWith('static final '),
          isTrue,
          reason: '$path:${index + 1} compiles a regex on an editor hot path',
        );
      }
    }
  });
}
