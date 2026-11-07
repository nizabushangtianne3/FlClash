import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

class _Probe {
  int menuBuilds = 0;
  int childBuilds = 0;
}

class _Counter extends StatelessWidget {
  const _Counter(this.probe);

  final _Probe probe;

  @override
  Widget build(BuildContext context) {
    probe.childBuilds++;
    return const SizedBox.expand();
  }
}

class _Harness extends StatelessWidget {
  const _Harness({required this.probe, required this.moved});

  final _Probe probe;

  /// Reads as a change to what the menu reads.
  final bool moved;

  @override
  Widget build(BuildContext context) {
    return CachedMenu(
      inputs: [moved],
      menuItemsOf: () {
        probe.menuBuilds++;
        return [
          PopupMenuItem(label: moved ? 'moved' : 'held', onPressed: () {}),
        ];
      },
      child: _Counter(probe),
    );
  }
}

List<PopupMenuItem>? _menuItems(WidgetTester tester) =>
    tester.widget<ContextMenuRegion>(find.byType(ContextMenuRegion)).menuItems;

void main() {
  testWidgets('holds the menu until what it reads changes', (tester) async {
    final probe = _Probe();
    await tester.pumpWidget(
      TestApp(child: _Harness(probe: probe, moved: false)),
    );

    expect(probe.menuBuilds, 1);
    expect(probe.childBuilds, 1);
    final held = _menuItems(tester);
    expect(held?.single.label, 'held');

    await tester.pumpWidget(
      TestApp(child: _Harness(probe: probe, moved: false)),
    );

    expect(probe.childBuilds, 2);
    expect(probe.menuBuilds, 1);
    expect(identical(_menuItems(tester), held), isTrue);

    await tester.pumpWidget(
      TestApp(child: _Harness(probe: probe, moved: true)),
    );

    expect(probe.menuBuilds, 2);
    expect(probe.childBuilds, 3);
    expect(_menuItems(tester)?.single.label, 'moved');
  });
}
