import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
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

typedef _Selection = ({String groupName, String proxyName});

class _RecordingProxiesAction extends ProxiesAction {
  final selections = <_Selection>[];

  @override
  void changeProxyDebounce(String groupName, String proxyName) {
    selections.add((groupName: groupName, proxyName: proxyName));
  }
}

const _nodeName = 'Node A';
const _groupName = 'Auto';

const _group = Group(
  name: _groupName,
  type: GroupType.URLTest,
  all: [
    Proxy(name: _nodeName, type: 'ss'),
    Proxy(name: 'Node B', type: 'ss'),
  ],
);

void main() {
  late _RecordingProxiesAction action;
  late ProviderContainer container;

  void setUpContainer({Map<String, String> selectedMap = const {}}) {
    final profile = Profile.normal().copyWith(selectedMap: selectedMap);
    action = _RecordingProxiesAction();
    container = ProviderContainer(
      overrides: [
        currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
        profilesProvider.overrideWith(() => TestProfiles([profile])),
        proxiesActionProvider.overrideWith(() => action),
      ],
    );
    globalState.container = container;
    container.read(groupsProvider.notifier).value = [_group];
  }

  tearDown(() => container.dispose());

  Future<void> tapNode(WidgetTester tester, GroupType groupType) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Scaffold(
            body: ProxyCard(
              groupName: _groupName,
              groupType: groupType,
              proxy: const Proxy(name: _nodeName, type: 'ss'),
              type: ProxyCardType.expand,
              testUrl: null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(ProxyCard));
    await tester.pump();
  }

  testWidgets('pins the node a computed group picked itself', (tester) async {
    setUpContainer();

    await tapNode(tester, GroupType.URLTest);

    expect(action.selections, [(groupName: _groupName, proxyName: _nodeName)]);
  });

  testWidgets('clears the pin when the pinned node is tapped again', (
    tester,
  ) async {
    setUpContainer(selectedMap: const {_groupName: _nodeName});

    await tapNode(tester, GroupType.URLTest);

    expect(action.selections, [(groupName: _groupName, proxyName: '')]);
  });

  testWidgets('a selector always picks the node that was tapped', (
    tester,
  ) async {
    setUpContainer(selectedMap: const {_groupName: _nodeName});

    await tapNode(tester, GroupType.Selector);

    expect(action.selections, [(groupName: _groupName, proxyName: _nodeName)]);
  });

  testWidgets('a group that cannot be picked reports instead of switching', (
    tester,
  ) async {
    setUpContainer();

    await tapNode(tester, GroupType.LoadBalance);

    expect(action.selections, isEmpty);
  });
}
