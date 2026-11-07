import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

IconSetIcon _icon(String name, String url) => IconSetIcon(name: name, url: url);

void main() {
  group('matchIconNames', () {
    test('ranks exact, contained, and containing names', () {
      final icons = [
        _icon('node.png', 'https://cdn.example.com/node.png'),
        _icon('Node_1.png', 'https://cdn.example.com/1.png'),
        _icon('server.png', 'https://cdn.example.com/server.png'),
      ];

      final matches = matchIconNames(icons, 'node');

      expect(matches.map((match) => match.index), [0, 1]);
      expect(matches.first.score, 3);
      expect(matches.last.score, 1);
    });

    test('matches a name a target contains only when the name is long', () {
      final icons = [_icon('united.png', 'https://cdn.example.com/1.png')];

      expect(matchIconNames(icons, 'unitedstates').single.score, 2);
      expect(matchIconNames(icons, 'un'), isEmpty);
    });

    test('ignores names with no Latin letters or digits', () {
      final icons = [_icon('中文.png', 'https://a/b.png')];

      expect(matchIconNames(icons, 'node'), isEmpty);
    });
  });

  group('rankIconMatches', () {
    test('keeps the first image of each url, best score first', () {
      final first = _icon('node.png', 'https://cdn.example.com/shared.png');
      final second = _icon('server.png', 'https://cdn.example.com/shared.png');
      final icons = [first, second];

      final ranked = rankIconMatches(icons.scoreFor('node server'));

      expect(ranked.map((icon) => icon.url), [
        'https://cdn.example.com/shared.png',
      ]);
    });
  });
}
