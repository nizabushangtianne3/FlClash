import 'package:dynamic_color/dynamic_color.dart';
import 'package:fl_clash/common/color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('opacity extensions use their named alpha values', () {
    const color = Colors.blue;
    const tolerance = 0.0001;

    expect(color.opacity80.a, closeTo(0.8, tolerance));
    expect(color.opacity50.a, closeTo(0.5, tolerance));
    expect(color.opacity10.a, closeTo(0.1, tolerance));
    expect(color.opacity3.a, closeTo(0.03, tolerance));
    expect(color.opacity0.a, 0);
  });

  test('harmonized accents match the dynamic colour blend', () {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2F6BFF));

    expect(scheme.success, Colors.green.harmonizeWith(scheme.primary));
    expect(scheme.warning, Colors.orange.harmonizeWith(scheme.primary));
  });

  test('harmonized accents are resolved once per scheme', () {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2F6BFF));
    final other = ColorScheme.fromSeed(seedColor: const Color(0xFFB3261E));

    expect(identical(scheme.success, scheme.success), isTrue);
    expect(identical(scheme.success, other.success), isFalse);
  });

  test('delay colours follow the delay bands', () {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2F6BFF));

    expect(scheme.delayColor(null), isNull);
    expect(scheme.delayColor(-1), scheme.error);
    expect(scheme.delayColor(120), scheme.success);
    expect(scheme.delayColor(900), scheme.warning);
  });
}
