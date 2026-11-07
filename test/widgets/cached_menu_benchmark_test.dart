@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

TrackerInfo _row(int index) {
  return TrackerInfo(
    id: '$index',
    start: DateTime.utc(2026).add(Duration(seconds: index)),
    metadata: Metadata(
      network: 'tcp',
      host: 'host-$index.test',
      destinationIP: '1.2.3.4',
      destinationPort: '443',
      process: 'com.android.chrome',
      uid: 10123,
    ),
    chains: const ['Proxy', 'DIRECT'],
    rule: 'DOMAIN-SUFFIX',
    rulePayload: 'example-$index.com',
  );
}

class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('holding a table row menu within the budget', (tester) async {
    const count = 500;
    const attempts = 2000;
    final rows = [for (var index = 0; index < count; index++) _row(index)];
    await tester.pumpWidget(const TestApp(child: _Host()));
    final context = tester.element(find.byType(_Host));

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final row in rows) {
        trackerInfoMenuItems(context, row);
      }
    }
    stopwatch.stop();
    final rebuiltUs = stopwatch.elapsedMicroseconds / attempts;

    // What a rebuild pays with the menu held: a counter-only update leaves
    // the metadata the menu reads in place, so the inputs still compare
    // equal even though the row object moved.
    final held = [
      for (final row in rows) [row.metadata, null],
    ];
    final moved = [
      for (final row in rows) [row.copyWith(upload: 1).metadata, null],
    ];
    stopwatch.reset();
    stopwatch.start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      var same = true;
      for (var index = 0; index < count; index++) {
        if (!listEquals(held[index], moved[index])) {
          same = false;
        }
      }
      if (!same) {
        fail('lost the held menu inputs');
      }
    }
    stopwatch.stop();
    final heldUs = stopwatch.elapsedMicroseconds / attempts;

    stdout.writeln(
      'cachedMenu rows=$count attempts=$attempts '
      'rebuiltUs=$rebuiltUs heldUs=$heldUs',
    );
  });
}
