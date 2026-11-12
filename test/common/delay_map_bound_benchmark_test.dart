@Skip('Manual performance benchmark')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/preferences.dart';

/// The shape a large import leaves behind: the two urls every profile tests,
/// each holding a name for every node the subscription ever carried.
Map<String, Map<String, int?>> _imported({
  required int names,
  required int urls,
}) {
  return {
    for (var u = 0; u < urls; u++)
      'https://www.gstatic.com/generate_204': {
        for (var i = 0; i < names; i++) 'node-$i-relay-name-$i': i % 900,
      },
  };
}

void main() {
  test('an unbounded map costs what its persist pays', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await mockPreferences();
    final store = await SharedPreferences.getInstance();

    for (final names in [1000, 51757, 200000]) {
      final map = _imported(names: names, urls: 1);
      final raw = json.encode(map);

      final before = store.getString('delay_map');
      final stopwatch = Stopwatch()..start();
      await preferences.saveDelayMap(map);
      stopwatch.stop();

      final stored = store.getString('delay_map')!;
      final trimmed = stored.length / raw.length;
      stdout.writeln(
        'delayMapBound names=$names '
        'unboundedBytes=${raw.length} storedBytes=${stored.length} '
        'trimmed=${(trimmed * 100).toStringAsFixed(1)}% '
        'saveUs=${stopwatch.elapsedMicroseconds} '
        'wasPresent=${before != null}',
      );
    }
  });
}
