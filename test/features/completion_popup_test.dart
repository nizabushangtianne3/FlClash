import 'package:code_forge/code_forge.dart';
import 'package:fl_clash/features/editor/completion_popup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _suggestions = [
  CodeForgeSuggestion(label: 'enable'),
  CodeForgeSuggestion(label: 'ipv6', detail: 'bool'),
  CodeForgeSuggestion(label: 'listen'),
];

const _widerSuggestions = [
  CodeForgeSuggestion(label: 'a considerably longer label'),
  CodeForgeSuggestion(
    label: 'and one wider still',
    detail: 'with a detail too',
  ),
];

Widget _popup(
  int? selected, {
  ValueChanged<int> onAccept = _ignore,
  List<CodeForgeSuggestion> suggestions = _suggestions,
}) => MaterialApp(
  home: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: EditorCompletionPopup(
        textStyle: const TextStyle(fontSize: 14),
        details: CodeForgeSuggestionDetails(
          suggestions: suggestions,
          selectedIndex: selected,
          onAccept: onAccept,
          caretRect: Rect.zero,
        ),
      ),
    ),
  ),
);

void _ignore(int _) {}

void main() {
  testWidgets('the popup lists every suggestion with its detail', (
    tester,
  ) async {
    await tester.pumpWidget(_popup(1));

    for (final label in ['enable', 'ipv6', 'listen', 'bool']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('moving the highlight holds the list as it was', (tester) async {
    await tester.pumpWidget(_popup(1));
    final first = tester.getSize(find.byType(EditorCompletionPopup));

    await tester.pumpWidget(_popup(2));
    await tester.pump();

    for (final label in ['enable', 'ipv6', 'listen', 'bool']) {
      expect(find.text(label), findsOneWidget);
    }
    // The rows are laid out from the labels, which the highlight does not move.
    expect(tester.getSize(find.byType(EditorCompletionPopup)), first);
  });

  testWidgets('a tap accepts the row it lands on', (tester) async {
    final accepted = <int>[];
    await tester.pumpWidget(_popup(null, onAccept: accepted.add));

    await tester.tap(find.text('listen'));
    await tester.pumpAndSettle();

    expect(accepted, [2]);
  });

  testWidgets('a different set of suggestions re-lays the popup out', (
    tester,
  ) async {
    await tester.pumpWidget(_popup(null));
    final first = tester.getSize(find.byType(EditorCompletionPopup));

    await tester.pumpWidget(_popup(null, suggestions: _widerSuggestions));
    await tester.pump();

    for (final label in [
      'a considerably longer label',
      'and one wider still',
      'with a detail too',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(
      tester.getSize(find.byType(EditorCompletionPopup)).width,
      greaterThan(first.width),
    );
  });
}
