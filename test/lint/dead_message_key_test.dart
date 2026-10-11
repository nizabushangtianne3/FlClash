import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// A key every locale carries and nothing reads is a translation nobody sees.
void main() {
  test('every arb key is read from lib through its accessor', () {
    final reference =
        jsonDecode(File('arb/intl_en.arb').readAsStringSync())
            as Map<String, Object?>;
    final keys = [
      for (final key in reference.keys)
        if (!key.startsWith('@')) key,
    ];
    expect(keys, isNotEmpty, reason: 'reading arb/intl_en.arb broke');

    final buffer = StringBuffer();
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final path = entity.path.replaceAll(r'\', '/');
      if (path.contains('/generated/') || path.contains('/l10n/')) {
        continue;
      }
      buffer.writeln(entity.readAsStringSync());
    }
    final source = buffer.toString();
    final orphans = [
      for (final key in keys)
        if (!RegExp(r'\.' + RegExp.escape(key) + r'\b').hasMatch(source)) key,
    ];

    expect(
      orphans,
      isEmpty,
      reason:
          'These keys are in every arb file but nothing in lib reads them '
          'through an accessor. Read them, or delete them from every arb:\n  '
          '${orphans.join('\n  ')}',
    );
  });
}
