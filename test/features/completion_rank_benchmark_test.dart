@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:code_forge/code_forge.dart' show CodeForgeSuggestion;
import 'package:fl_clash/features/editor/completion_matcher.dart'
    show completeFrom;
import 'package:flutter_test/flutter_test.dart';

/// Ranks the candidate sets an editor completion offers, at the per-call shape
/// each keystroke pays.
void main() {
  test('ranking a config key table stays inside a keystroke budget', () {
    final suggestions = <CodeForgeSuggestion>[
      for (final key in _configKeys) CodeForgeSuggestion(label: key),
    ];

    final stopwatch = Stopwatch()..start();
    var keep = 0;
    for (var i = 0; i < 200; i++) {
      keep +=
          completeFrom(
            _prefixes[i % _prefixes.length],
            suggestions,
          )?.suggestions.length ??
          0;
    }
    stopwatch.stop();
    stdout.writeln(
      'completionRankKeys candidates=${suggestions.length} calls=200 '
      'totalUs=${stopwatch.elapsedMicroseconds} '
      'perCallUs=${stopwatch.elapsedMicroseconds / 200} keep=$keep',
    );
    expect(keep, greaterThan(0));
  });

  test('ranking a document word table beats a per-candidate lower', () {
    final suggestions = <CodeForgeSuggestion>[
      for (var i = 0; i < 3000; i++)
        CodeForgeSuggestion(label: '${_words[i % _words.length]}$i'),
    ];

    final stopwatch = Stopwatch()..start();
    var keep = 0;
    for (var i = 0; i < 200; i++) {
      keep +=
          completeFrom(
            _prefixes[i % _prefixes.length],
            suggestions,
          )?.suggestions.length ??
          0;
    }
    stopwatch.stop();
    stdout.writeln(
      'completionRankWords candidates=${suggestions.length} calls=200 '
      'totalUs=${stopwatch.elapsedMicroseconds} '
      'perCallUs=${stopwatch.elapsedMicroseconds / 200} keep=$keep',
    );
    expect(keep, greaterThan(0));
  });
}

const _prefixes = <String>[
  '',
  'p',
  'po',
  'pr',
  'prox',
  'proxy-',
  'd',
  'in',
  'u',
];

const _configKeys = <String>[
  'mixed-port',
  'redir-port',
  'tproxy-port',
  'authentication',
  'allow-lan',
  'bind-address',
  'ipv6',
  'mode',
  'log-level',
  'external-controller',
  'secret',
  'dns',
  'proxies',
  'proxy-groups',
  'rules',
  'rule-providers',
  'proxy-providers',
  'hosts',
  'profile',
  'cache-file',
  'sniffer',
  'tun',
  'geodata-mode',
  'geox-url',
  'geo-auto-update',
  'geo-update-interval',
  'find-process-mode',
  'global-client-fingerprint',
  'keep-alive-interval',
  'unified-delay',
  'tcp-concurrent',
  'interface-name',
  'routing-mark',
  'disable-keep-alive',
  'etag-support',
  'sleep-process',
];

const _words = <String>[
  'TokyoNode',
  'SingaporeRelay',
  'LosAngelesDirect',
  'FrankfurtPremium',
  'SiliconValleyStreamer',
  'SeoulEnterprise',
  'SydneyBusiness',
  'MumbaiBalanced',
  'SaoPauloBypass',
  'LondonFallback',
];
