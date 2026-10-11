import 'dart:io';

import 'package:test/test.dart';

import '../../tool/changelog.dart' show releaseRepository;

void main() {
  test('the release notes link the repository that publishes them', () {
    final template = File('.github/release_template.md').readAsStringSync();
    expect(
      template,
      contains('https://github.com/REPOSITORY/releases/download/vVERSION/'),
    );
    expect(
      template,
      isNot(contains('github.com/chen08209/FlClash')),
      reason: 'a fork publishing these notes has no releases under upstream',
    );

    final workflow = File('.github/workflows/build.yaml').readAsStringSync();
    expect(
      workflow,
      contains(r'REPOSITORY|$GITHUB_REPOSITORY'),
      reason: 'the token has to be substituted when the release body is built',
    );

    final poster = File('release_telegram.py').readAsStringSync();
    expect(poster, contains('os.getenv("GITHUB_REPOSITORY"'));
    expect(
      poster,
      isNot(contains('github.com/chen08209/FlClash')),
      reason: 'the post is made by the repository that is releasing',
    );
  });

  test('the changelog tool follows the publishing repository', () {
    expect(
      releaseRepository({'GITHUB_REPOSITORY': 'someone/FlClash'}),
      'someone/FlClash',
    );
    expect(releaseRepository(const {}), 'chen08209/FlClash');
  });
}
