import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/views/dashboard/widgets/feed_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _countProvider = NotifierProvider<_CountNotifier, int>(
  _CountNotifier.new,
);

class _CountNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void set(int value) => state = value;
}

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() {
    container.dispose();
  });

  Future<void> pumpCount(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: ThrottledFeedCount(provider: _countProvider)),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('does not schedule a repaint for an unchanged count', (
    tester,
  ) async {
    await pumpCount(tester);

    expect(find.text('0'), findsOneWidget);
    container.read(_countProvider.notifier).set(0);
    await tester.pump();

    await tester.binding.delayed(renderThrottleDuration);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('still repaints after a count changes', (tester) async {
    await pumpCount(tester);

    container.read(_countProvider.notifier).set(1);
    await tester.pump();
    await tester.binding.delayed(renderThrottleDuration);
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pump();
    expect(find.text('1'), findsOneWidget);
  });
}
