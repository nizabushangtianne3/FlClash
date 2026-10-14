import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/connection/connections.dart';
import 'package:fl_clash/views/dashboard/widgets/connections.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';

class MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockCoreHandlerInterface core;
  late ProviderContainer container;

  setUpAll(() {
    core = MockCoreHandlerInterface();
    CoreController.resetInstance();
    CoreController.test(core);
  });

  tearDownAll(CoreController.resetInstance);

  setUp(() {
    reset(core);
    when(() => core.getConnections()).thenAnswer((_) async => const []);
    container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(TestProfiles.new)],
    );
    globalState.container = container;
    container.read(viewSizeProvider.notifier).value = const Size(1200, 1000);
  });

  tearDown(() => container.dispose());

  Future<void> pumpCard(
    WidgetTester tester, {
    Size size = const Size(1200, 1000),
    Future<int> Function()? countReader,
    Locale? locale,
  }) async {
    container.read(viewSizeProvider.notifier).value = size;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          locale: locale,
          child: Scaffold(
            body: ListView(
              children: [ConnectionsCard(countReader: countReader)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> teardownCard(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('counts what the Core is holding open', (tester) async {
    var count = 2;
    await pumpCard(tester, countReader: () async => count);

    expect(find.text('Live connections'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    count = 1;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('1'), findsOneWidget);

    await teardownCard(tester);
  });

  testWidgets('a large count is shortened with K and M in any locale', (
    tester,
  ) async {
    await pumpCard(
      tester,
      locale: const Locale('zh', 'CN'),
      countReader: () async => 12345,
    );

    expect(find.text('12.3K'), findsOneWidget);

    await teardownCard(tester);
  });

  testWidgets('tapping the card opens the connections in a sheet', (
    tester,
  ) async {
    await pumpCard(
      tester,
      size: const Size(400, 800),
      countReader: () async => 0,
    );

    await tester.tap(find.byType(ConnectionsCard));
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionsView), findsOneWidget);

    await teardownCard(tester);
  });

  testWidgets('a count update reuses the static header', (tester) async {
    var count = 1;
    await pumpCard(tester, countReader: () async => count);

    final headerBefore = tester.widget<InfoHeader>(find.byType(InfoHeader));

    count = 2;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    final headerAfter = tester.widget<InfoHeader>(find.byType(InfoHeader));
    expect(identical(headerAfter, headerBefore), isTrue);
    expect(find.text('2'), findsOneWidget);

    await teardownCard(tester);
  });

  testWidgets('opening the sheet reuses the connection poll', (tester) async {
    var countCalls = 0;
    var snapshotCalls = 0;
    when(core.getConnections).thenAnswer((_) async {
      snapshotCalls++;
      return const [];
    });

    await pumpCard(
      tester,
      countReader: () async {
        countCalls++;
        return 0;
      },
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(countCalls, 1);
    expect(snapshotCalls, 0);

    await tester.tap(find.byType(ConnectionsCard));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(countCalls, 1);
    expect(snapshotCalls, greaterThanOrEqualTo(1));

    await teardownCard(tester);
  });
}
