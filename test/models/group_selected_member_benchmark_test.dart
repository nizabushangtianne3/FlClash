@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolving a selected member of a large group stays cheap', () {
    const count = 1000;
    const attempts = 10000;
    final all = [
      for (var index = 0; index < count; index++)
        Proxy(name: 'proxy-$index', type: 'ss'),
    ];
    final group = Group(name: 'G', type: GroupType.Selector, all: all);

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final selected = group.getCurrentSelectedName('proxy-${count - 1}');
      if (selected != 'proxy-${count - 1}') {
        fail('wrong member');
      }
    }
    stopwatch.stop();
    stdout.writeln(
      'groupSelectedMember count=$count attempts=$attempts '
      'totalUs=${stopwatch.elapsedMicroseconds}',
    );
  });
}
