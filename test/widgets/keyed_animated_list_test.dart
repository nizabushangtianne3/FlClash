import 'package:fl_clash/ui/keyed_animated_list.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    keyedAnimatedListIndexBuilds = 0;
  });

  Widget buildList(List<String> items) {
    return MaterialApp(
      home: Scaffold(
        body: KeyedAnimatedList<String>(
          items: items,
          keyOf: (item) => item,
          separator: const Divider(height: 0),
          itemBuilder: (_, item, _) => SizedBox(
            key: ValueKey('row-$item'),
            height: 40,
            child: Text(item),
          ),
        ),
      ),
    );
  }

  double topOf(WidgetTester tester, String item) {
    return tester.getTopLeft(find.byKey(ValueKey('row-$item'))).dy;
  }

  testWidgets('removed item collapses before leaving the tree', (tester) async {
    await tester.pumpWidget(buildList(const ['a', 'b', 'c']));
    await tester.pumpWidget(buildList(const ['a', 'c']));
    await tester.pump();

    expect(find.text('b'), findsOneWidget);
    final midway = topOf(tester, 'c');
    await tester.pump(const Duration(milliseconds: 150));
    expect(topOf(tester, 'c'), lessThan(midway));

    await tester.pumpAndSettle();
    expect(find.text('b'), findsNothing);
    expect(topOf(tester, 'c'), 40);
  });

  testWidgets('reordered item slides from its old slot', (tester) async {
    await tester.pumpWidget(buildList(const ['a', 'b', 'c']));
    expect(topOf(tester, 'c'), 80);

    await tester.pumpWidget(buildList(const ['c', 'a', 'b']));
    await tester.pump();

    final render = tester.renderObject(find.byKey(const ValueKey('row-c')));
    Offset paintedTop() => (render as RenderBox).localToGlobal(Offset.zero);
    expect(paintedTop().dy, closeTo(80, 0.01));

    await tester.pump(const Duration(milliseconds: 150));
    final midway = paintedTop().dy;
    expect(midway, greaterThan(0));
    expect(midway, lessThan(80));

    await tester.pumpAndSettle();
    expect(paintedTop().dy, closeTo(0, 0.01));
    expect(tester.takeException(), null);
  });

  testWidgets('item inserted and removed before it grows is dropped', (
    tester,
  ) async {
    await tester.pumpWidget(buildList(const ['a']));
    await tester.pumpWidget(buildList(const ['a', 'b']));
    await tester.pumpWidget(buildList(const ['a']));
    expect(tester.takeException(), null);

    await tester.pumpAndSettle();
    expect(find.text('b'), findsNothing);
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('item removed and re-added keeps a single row', (tester) async {
    await tester.pumpWidget(buildList(const ['a', 'b']));
    await tester.pumpWidget(buildList(const ['a']));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(buildList(const ['a', 'b']));
    await tester.pumpAndSettle();

    expect(find.text('b'), findsOneWidget);
    expect(topOf(tester, 'b'), 40);
  });

  testWidgets('rows entering in one update share a single ticker', (
    tester,
  ) async {
    final visible = [for (var i = 0; i < 30; i++) '$i'];
    await tester.pumpWidget(buildList(visible));
    await tester.pumpWidget(
      buildList([...visible, for (var i = 30; i < 70; i++) '$i']),
    );
    await tester.pump();

    expect(tester.binding.transientCallbackCount, 1);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a change too large to animate swaps the rows at once', (
    tester,
  ) async {
    final many = [for (var i = 0; i < 100; i++) '$i'];
    await tester.pumpWidget(buildList(many));
    await tester.pumpWidget(buildList(const ['0', '1']));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(KeyedAnimatedList<String>),
        matching: find.byType(SizeTransition),
      ),
      findsNothing,
    );
    expect(find.text('2'), findsNothing);
    expect(topOf(tester, '1'), 40);

    await tester.pumpWidget(buildList(many));
    await tester.pump();
    expect(find.text('10'), findsOneWidget);
    expect(topOf(tester, '10'), 400);
  });

  testWidgets('a row is built with its position among the items', (
    tester,
  ) async {
    final positions = <String, int?>{};
    Widget buildList(List<String> items) {
      return MaterialApp(
        home: Scaffold(
          body: KeyedAnimatedList<String>(
            items: items,
            keyOf: (item) => item,
            itemBuilder: (_, item, index) {
              positions[item] = index;
              return SizedBox(
                key: ValueKey('row-$item'),
                height: 40,
                child: Text(item),
              );
            },
          ),
        ),
      );
    }

    await tester.pumpWidget(buildList(const ['a', 'b', 'c']));
    expect(positions, {'a': 0, 'b': 1, 'c': 2});

    await tester.pumpWidget(buildList(const ['c', 'a']));
    expect(positions, {'a': 1, 'b': null, 'c': 0});

    await tester.pumpAndSettle();
    expect(find.text('b'), findsNothing);
  });

  testWidgets('a rebuild with the same items keeps the index table', (
    tester,
  ) async {
    const items = ['a', 'b', 'c'];
    await tester.pumpWidget(buildList(items));
    expect(keyedAnimatedListIndexBuilds, 1);

    await tester.pumpWidget(buildList(items));
    expect(keyedAnimatedListIndexBuilds, 1);
  });

  testWidgets('a refresh over new item objects builds it once', (tester) async {
    await tester.pumpWidget(buildList(const ['a', 'b', 'c']));
    expect(keyedAnimatedListIndexBuilds, 1);

    await tester.pumpWidget(buildList(['a', 'b', 'c']));
    await tester.pump();
    expect(keyedAnimatedListIndexBuilds, 2);
  });
}
