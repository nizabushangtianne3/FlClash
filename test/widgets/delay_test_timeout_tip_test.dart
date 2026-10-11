import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/status_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_profiles.dart';

class _MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

const _testUrl = 'http://delay.test';

const _nodes = [
  Proxy(name: 'HK-01', type: 'ss'),
  Proxy(name: 'HK-02', type: 'ss'),
];

const _group = Group(name: 'Proxy', type: GroupType.Selector, all: _nodes);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockCoreHandlerInterface core;
  late ProviderContainer container;

  setUpAll(() async {
    await AppLocalizations.load(const Locale('en'));
  });

  setUp(() {
    core = _MockCoreHandlerInterface();
    container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        profilesProvider.overrideWith(TestProfiles.new),
        currentProfileIdProvider.overrideWithBuild((_, _) => null),
      ],
    );
    globalState.container = container;
    container.read(appSettingProvider.notifier).value = const AppSettingProps(
      testUrl: _testUrl,
    );
    container.read(groupsProvider.notifier).value = [_group];
  });

  tearDown(() => container.dispose());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: globalState.navigatorKey,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          builder: (_, child) => StatusManager(child: child!),
          home: const SizedBox(),
        ),
      ),
    );
    await tester.pump();
  }

  /// Drains the notification's own timers so the binding stays clean.
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpWidget(const SizedBox.shrink());
  }

  void answersWith(int Function(String name) delayOf) {
    when(() => core.asyncTestDelay(any(), any())).thenAnswer((
      invocation,
    ) async {
      final name = invocation.positionalArguments[1] as String;
      return Delay(
        url: invocation.positionalArguments[0] as String,
        name: name,
        value: delayOf(name),
      );
    });
  }

  testWidgets('says so when a sweep timed out on every node', (tester) async {
    answersWith((_) => -1);
    await pumpApp(tester);

    await container.read(proxiesActionProvider.notifier).delayTestGroups([
      _group,
    ]);
    await tester.pump();

    expect(
      find.text(currentAppLocalizations.delayTestAllTimeout),
      findsOneWidget,
    );
    await drainTimers(tester);
  });

  testWidgets('stays quiet when a node answered', (tester) async {
    answersWith((name) => name == 'HK-01' ? 120 : -1);
    await pumpApp(tester);

    await container.read(proxiesActionProvider.notifier).delayTestGroups([
      _group,
    ]);
    await tester.pump();

    expect(
      find.text(currentAppLocalizations.delayTestAllTimeout),
      findsNothing,
    );
    await drainTimers(tester);
  });

  testWidgets('stays quiet for a single node test', (tester) async {
    answersWith((_) => -1);
    await pumpApp(tester);

    await container
        .read(proxiesActionProvider.notifier)
        .proxyDelayTest(_nodes.first);
    await tester.pump();

    expect(
      find.text(currentAppLocalizations.delayTestAllTimeout),
      findsNothing,
    );
    await drainTimers(tester);
  });
}
