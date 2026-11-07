@Skip('Manual performance benchmark')
library;

import 'dart:io';

import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('resolving a table row text style within the budget', (
    tester,
  ) async {
    const attempts = 20000;
    await tester.pumpWidget(const TestApp(child: _Host()));
    final context = tester.element(find.byType(_Host));

    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      final style = AppTextStyle.subheadline.of(context);
      style.copyWith(
        color: context.colorScheme.onSurface,
        height: 20 / style.fontSize!,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      AppShape.all(AppCorner.fit(48));
    }
    stopwatch.stop();
    final perCallUs = stopwatch.elapsedMicroseconds / attempts;

    final shared = AppTextStyle.subheadline
        .of(context)
        .copyWith(
          color: context.colorScheme.onSurface,
          height: 20 / AppTextStyle.subheadline.size,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    final shape = AppShape.all(AppCorner.fit(48));
    stopwatch.reset();
    stopwatch.start();
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (identical(shared, shared) && identical(shape, shape)) {
        continue;
      }
    }
    stopwatch.stop();
    final hoistedUs = stopwatch.elapsedMicroseconds / attempts;

    stdout.writeln(
      'rowStyle attempts=$attempts perRowUs=$perCallUs hoistedUs=$hoistedUs',
    );
  });
}
