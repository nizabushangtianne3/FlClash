import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/icons/icons.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/proxies/card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

const _nodeName = 'Node A';
const _group = Group(
  name: 'Auto',
  type: GroupType.URLTest,
  all: [Proxy(name: _nodeName, type: 'ss')],
);

Finder _clock() => find.byWidgetPredicate(
  (widget) => widget is GlyphIcon && widget.glyph == AppGlyphs.clock,
);

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        currentProfileIdProvider.overrideWithBuild((_, _) => null),
        profilesProvider.overrideWith(TestProfiles.new),
      ],
    );
    globalState.container = container;
    container.read(groupsProvider.notifier).value = [_group];
  });

  tearDown(() => container.dispose());

  void setDelay(int value) {
    container
        .read(delayDataSourceProvider.notifier)
        .setDelay(Delay(url: defaultTestUrl, name: _nodeName, value: value));
  }

  void queue() {
    container
        .read(pendingDelayTestsProvider.notifier)
        .apply(acquired: {delayTestKey(defaultTestUrl, _nodeName)});
  }

  Future<void> pumpCard(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(
          child: Scaffold(
            body: ProxyCard(
              groupName: 'Auto',
              groupType: GroupType.URLTest,
              proxy: Proxy(name: _nodeName, type: 'ss'),
              type: ProxyCardType.expand,
              testUrl: null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a queued node keeps the delay the sort placed it by', (
    tester,
  ) async {
    setDelay(473);
    queue();

    await pumpCard(tester);

    expect(find.text('473 ms'), findsOneWidget);
    expect(_clock(), findsNothing);
  });

  testWidgets('a queued node with nothing measured shows the clock', (
    tester,
  ) async {
    queue();

    await pumpCard(tester);

    expect(find.text('Timeout'), findsNothing);
    expect(_clock(), findsOneWidget);
  });

  testWidgets('a measured node that is not queued keeps its value', (
    tester,
  ) async {
    setDelay(-1);

    await pumpCard(tester);

    expect(find.text('Timeout'), findsOneWidget);
    expect(_clock(), findsNothing);
  });
}
