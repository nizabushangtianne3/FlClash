import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/disclaimer.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  const size = Size(1400, 1600);
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    globalState.container = container;
    container.read(viewSizeProvider.notifier).update((_) => size);
  });

  Future<bool?> chooseConsent(WidgetTester tester, Finder button) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    bool? accepted;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  accepted = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const DisclaimerView(requireConsent: true),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    return accepted;
  }

  testWidgets('agreeing resolves the consent as given', (tester) async {
    final accepted = await chooseConsent(
      tester,
      find.widgetWithText(FilledButton, 'Agree'),
    );

    expect(accepted, isTrue);
  });

  testWidgets('leaving the page declines the consent', (tester) async {
    final accepted = await chooseConsent(
      tester,
      find.widgetWithText(OutlinedButton, 'Exit'),
    );

    expect(accepted, isFalse);
  });
}
