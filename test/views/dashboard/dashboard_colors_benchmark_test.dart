library;

import 'dart:io';

import 'package:fl_clash/views/dashboard/style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('reading the dashboard colors a card pays for', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => const SizedBox(key: ValueKey('root')),
        ),
      ),
    );
    final context = tester.element(find.byKey(const ValueKey('root')));

    const attempts = 200000;
    DashboardColors.of(context);
    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      DashboardColors.of(context);
    }
    stopwatch.stop();
    stdout.writeln(
      'dashboardColorsOf attempts=$attempts '
      'perReadNs=${stopwatch.elapsedMicroseconds * 1000 / attempts}',
    );

    final direct = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      Theme.of(context).colorScheme.surfaceContainerHighest.hashCode;
    }
    direct.stop();
    stdout.writeln(
      'themeLookupOnce attempts=$attempts '
      'perReadNs=${direct.elapsedMicroseconds * 1000 / attempts}',
    );

    // Three reads a build already makes when it holds the scheme locally vs.
    // each one looking the theme up again.
    final scheme = Theme.of(context).colorScheme;
    final hoisted = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final local = scheme;
      local.surfaceContainerHighest.hashCode +
          local.surfaceContainer.hashCode +
          local.surfaceContainerHigh.hashCode;
    }
    hoisted.stop();
    stdout.writeln(
      'threeReadsHoisted attempts=$attempts '
      'perReadNs=${hoisted.elapsedMicroseconds * 1000 / attempts}',
    );

    final lookedUp = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      Theme.of(context).colorScheme.surfaceContainerHighest.hashCode +
          Theme.of(context).colorScheme.surfaceContainer.hashCode +
          Theme.of(context).colorScheme.surfaceContainerHigh.hashCode;
    }
    lookedUp.stop();
    stdout.writeln(
      'threeReadsLookedUp attempts=$attempts '
      'perReadNs=${lookedUp.elapsedMicroseconds * 1000 / attempts}',
    );

    // What a holder keyed by the scheme it was built from would read: no
    // theme lookup and no color construction at all.
    final expando = Expando<DashboardColors>();
    expando[scheme] ??= DashboardColors.of(context);
    final cached = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      (expando[scheme] ?? DashboardColors.of(context)).hashCode;
    }
    cached.stop();
    stdout.writeln(
      'colorsSchemeCached attempts=$attempts '
      'perReadNs=${cached.elapsedMicroseconds * 1000 / attempts}',
    );
  });
}
