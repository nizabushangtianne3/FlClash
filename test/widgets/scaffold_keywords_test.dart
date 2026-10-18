import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('a parent rebuild does not report unchanged keywords', (
    tester,
  ) async {
    final updates = <List<String>>[];

    Widget page() {
      return CommonScaffold(
        title: 'Page',
        onKeywordsUpdate: (keywords) => updates.add(List.of(keywords)),
        body: Builder(
          builder: (context) {
            return Center(
              child: TextButton(
                onPressed: () {
                  context.commonScaffoldState?.addKeyword('needle');
                },
                child: const Text('add'),
              ),
            );
          },
        ),
      );
    }

    await tester.pumpWidget(TestApp(wrapInProviderScope: true, child: page()));
    await tester.pump();

    await tester.tap(find.text('add'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(updates, hasLength(1));
    expect(updates.single, ['needle']);

    await tester.pumpWidget(TestApp(wrapInProviderScope: true, child: page()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(updates, hasLength(1));
  });
}
