import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the site renderer normalizes CRLF before matching the template', () {
    final source = File('tool/render_site.mjs').readAsStringSync();
    final normalization = source.indexOf(r'.replace(/\r\n/g, ');

    expect(
      normalization,
      isNot(-1),
      reason:
          'a Windows checkout hands site/index.html CRLF, and the head '
          'patterns match a template that ends its line with a bare newline',
    );
    expect(
      normalization,
      lessThan(source.indexOf('function render(')),
      reason: 'the patterns match the template the renderer reads',
    );
  });
}
