import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/pages/error.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _stack = StackTrace.fromString('#0 boot (package:fl_clash/main.dart:1)');

/// The same MaterialApp the failure path in `main` builds.
Widget _screen({ThemeData? theme, Locale? locale}) {
  return MaterialApp(
    theme: theme,
    locale: locale,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: AppLocalizations.delegate.supportedLocales,
    home: InitErrorScreen(error: StateError('boot failed'), stack: _stack),
  );
}

void main() {
  testWidgets('shows the error and its stack trace', (tester) async {
    await tester.pumpWidget(_screen());

    expect(find.text('Startup failed'), findsOneWidget);
    expect(find.text('Error details'), findsOneWidget);
    expect(find.text('Stack trace'), findsOneWidget);
    expect(
      find.text(StateError('boot failed').toString()),
      findsOneWidget,
      reason: 'the raw error must stay readable when nothing else works',
    );
    expect(find.text(_stack.toString()), findsOneWidget);
  });

  testWidgets('names the failure in the language of the system', (
    tester,
  ) async {
    await tester.pumpWidget(_screen(locale: const Locale('zh', 'CN')));

    expect(find.text('启动失败'), findsOneWidget);
    expect(find.text('堆栈跟踪'), findsOneWidget);
    expect(
      find.text(StateError('boot failed').toString()),
      findsOneWidget,
      reason: 'the error itself is never translated',
    );
  });

  testWidgets('renders in both brightness modes', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        _screen(theme: ThemeData(brightness: brightness)),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(InitErrorScreen), findsOneWidget);
    }
  });

  testWidgets('copies the error and stack trace to the clipboard', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(_screen());
    await tester.tap(find.text('Copy details'));
    await tester.pump();

    expect(copied, hasLength(1));
    expect(copied.single, contains('boot failed'));
    expect(copied.single, contains(_stack.toString()));
    expect(find.text('Error details copied to clipboard'), findsOneWidget);
  });
}
