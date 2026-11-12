@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/views/dashboard/style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/typography.dart';

void main() {
  testWidgets('a figure the callers flatten pays what intl asks for it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => const SizedBox(key: ValueKey('root')),
        ),
      ),
    );
    final context = tester.element(find.byKey(const ValueKey('root')));

    const attempts = 200000;
    DashboardText.figure(context, AppTextStyle.title2);
    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      DashboardText.figure(context, AppTextStyle.title2);
    }
    stopwatch.stop();
    stdout.writeln(
      'figureRead attempts=$attempts '
      'perReadNs=${stopwatch.elapsedMicroseconds * 1000 / attempts}',
    );

    final flattened = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      DashboardText.figure(
        context,
        AppTextStyle.title2,
      ).copyWith(letterSpacing: 0);
    }
    flattened.stop();
    stdout.writeln(
      'figureThenFlattened attempts=$attempts '
      'perReadNs=${flattened.elapsedMicroseconds * 1000 / attempts}',
    );

    final flat = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      DashboardText.flatFigure(context, AppTextStyle.title2);
    }
    flat.stop();
    stdout.writeln(
      'flatFigureRead attempts=$attempts '
      'perReadNs=${flat.elapsedMicroseconds * 1000 / attempts}',
    );
  });
}
