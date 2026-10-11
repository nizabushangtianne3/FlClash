import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/connection/connections.dart';
import 'package:fl_clash/views/dashboard/widgets/connections.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';

class MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

TrackerInfo _connection(String id) => TrackerInfo(
  id: id,
  start: DateTime(2024),
  metadata: const Metadata(network: 'tcp', host: 'example.com'),
  chains: const ['proxy-a'],
  rule: 'MATCH',
  rulePayload: '',
);

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
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('counts what the Core is holding open', (tester) async {
    var count = 2;
    await pumpCard(tester, countReader: () async => count);

    expect(find.text('Live connections'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    count = 1;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(find.text('1'), findsOneWidget);

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

  testWidgets('closing the sheet releases its full snapshot', (tester) async {
    when(
      core.getConnections,
    ).thenAnswer((_) async => [_connection('connection-1')]);

    await pumpCard(tester, countReader: () async => 1);
    await tester.tap(find.byType(ConnectionsCard));
    await tester.pumpAndSettle();

    expect(container.read(connectionsProvider).connections, hasLength(1));

    Navigator.of(tester.element(find.byType(ConnectionsView))).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    final snapshot = container.read(connectionsProvider);
    expect(snapshot.count, 1);
    expect(snapshot.connections, isEmpty);

    await teardownCard(tester);
  });
}
