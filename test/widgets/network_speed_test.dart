import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/widget_metrics.dart';
import 'package:fl_clash/views/dashboard/widgets/network_speed.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('a traffic update reuses the static header', (tester) async {
    tester.view.physicalSize = const Size(360, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    globalState.container = container;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Scaffold(
            body: Center(
              child: SizedBox.square(
                dimension: 320,
                child: DashboardWidgetMetrics(
                  unitHeight: 80,
                  child: const NetworkSpeed(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final headerBefore = tester.widget<InfoHeader>(find.byType(InfoHeader));

    container
        .read(trafficsProvider.notifier)
        .addTraffic(const Traffic(up: 1024, down: 2048));
    await tester.pump();

    final headerAfter = tester.widget<InfoHeader>(find.byType(InfoHeader));
    expect(identical(headerAfter, headerBefore), isTrue);
    expect(find.textContaining('1KB/s'), findsOneWidget);
    expect(find.textContaining('2KB/s'), findsOneWidget);
  });
}
