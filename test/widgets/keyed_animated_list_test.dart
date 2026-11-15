import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart';
import '../helpers/host_scaffold.dart';
import '../helpers/test_app.dart';

void main() {
  Widget buildList(List<String> items) {
    return HostApp(
      home: HostScaffold(
        body: KeyedAnimatedList<String>(
          items: items,
          keyOf: (item) => item,
          separator: const Divider(height: 0),
          itemBuilder: (_, item) => SizedBox(
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
    await tester.pumpAndSettle();
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

  testWidgets('a row keeps its state as it settles', (tester) async {
    var mounts = 0;
    Widget build(List<String> items) => HostApp(
      home: HostScaffold(
        body: KeyedAnimatedList<String>(
          items: items,
          keyOf: (item) => item,
          itemBuilder: (_, item) => _CountsMounts(onMount: () => mounts++),
        ),
      ),
    );
    await tester.pumpWidget(build(const ['a']));
    await tester.pumpWidget(build(const ['b', 'a']));
    await tester.pump();
    expect(mounts, 2);

    await tester.pumpAndSettle();
    expect(mounts, 2);
  });

  testWidgets('a row far down keeps its state when the list shifts', (
    tester,
  ) async {
    final items = [for (var i = 0; i < 10; i++) '$i'];
    final state = GlobalKey<CountsMountsState>();
    Widget build(List<String> list) => HostApp(
      home: HostScaffold(
        body: KeyedAnimatedList<String>(
          items: list,
          keyOf: (item) => item,
          itemBuilder: (_, item) => item == '8'
              ? _CountsMounts(key: state)
              : const SizedBox(height: 40),
        ),
      ),
    );

    await tester.pumpWidget(build(items));
    await tester.pumpAndSettle();
    expect(find.byKey(state), findsOneWidget);

    // The row at the far end of the table has to keep its state when the
    // rows above it move, which is what the child index callback answers.
    await tester.pumpWidget(build([...items.take(9), 'new']));
    await tester.pumpAndSettle();
    expect(find.byKey(state), findsOneWidget);
  });

  testWidgets('a row keeps its state when a row above it leaves', (
    tester,
  ) async {
    final items = [for (var i = 0; i < 10; i++) '$i'];
    final state = GlobalKey<CountsMountsState>();
    Widget build(List<String> list) => HostApp(
      home: HostScaffold(
        body: KeyedAnimatedList<String>(
          items: list,
          keyOf: (item) => item,
          itemBuilder: (_, item) => item == '8'
              ? _CountsMounts(key: state)
              : const SizedBox(height: 40),
        ),
      ),
    );

    await tester.pumpWidget(build(items));
    await tester.pumpAndSettle();
    expect(find.byKey(state), findsOneWidget);

    await tester.pumpWidget(build(items.where((item) => item != '0').toList()));
    await tester.pumpAndSettle();
    expect(find.byKey(state), findsOneWidget);
  });
}

class _CountsMounts extends StatefulWidget {
  const _CountsMounts({this.onMount, super.key});

  final VoidCallback? onMount;

  @override
  State<_CountsMounts> createState() => CountsMountsState();
}

class CountsMountsState extends State<_CountsMounts> {
  @override
  void initState() {
    super.initState();
    widget.onMount?.call();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 40);
}
