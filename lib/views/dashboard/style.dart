import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';

class DashboardColors {
  const DashboardColors._({
    required this.page,
    required this.card,
    required this.tone,
    required this.tone2,
    required this.track,
    required this.thumb,
    required this.series2,
    required this.ok,
    required this.okContainer,
    required this.onOkContainer,
    required this.warn,
    required this.warnContainer,
    required this.onWarnContainer,
  });

  factory DashboardColors.of(BuildContext context) =>
      DashboardColors.ofScheme(context.colorScheme);

  /// The roles are a pure function of the scheme and every card asks for them
  /// once a build, so the answer hangs on the scheme it was built from.
  factory DashboardColors.ofScheme(ColorScheme colorScheme) {
    final cached = _cachedColors[colorScheme];
    if (cached != null) {
      return cached;
    }
    final card = SurfaceLevel.card.colorOf(colorScheme);
    return _cachedColors[colorScheme] = DashboardColors._(
      page: SurfaceLevel.page.colorOf(colorScheme),
      card: card,
      tone: SurfaceLevel.block.colorOf(colorScheme),
      tone2: SurfaceLevel.inset.colorOf(colorScheme),
      track: colorScheme.surfaceContainerHighest,
      thumb: colorScheme.outline,
      series2: Color.alphaBlend(
        colorScheme.primary.withValues(alpha: 0.45),
        card,
      ),
      ok: colorScheme.success,
      okContainer: colorScheme.successContainer,
      onOkContainer: colorScheme.onSuccessContainer,
      warn: colorScheme.warning,
      warnContainer: colorScheme.warningContainer,
      onWarnContainer: colorScheme.onWarningContainer,
    );
  }

  static final _cachedColors = Expando<DashboardColors>();
  final Color page;
  final Color card;

  final Color tone;

  final Color tone2;
  final Color track;
  final Color thumb;
  final Color series2;
  final Color ok;
  final Color okContainer;
  final Color onOkContainer;
  final Color warn;
  final Color warnContainer;
  final Color onWarnContainer;
}

/// Values are the design's CSS shadows. A CSS blur is twice its sigma while
/// Flutter turns a blur radius r into a sigma of 0.577 r + 0.5, so each one
/// goes through [_blur] or it renders a third heavier.
abstract final class DashboardShadows {
  static List<BoxShadow> e1Of(ColorScheme colorScheme) =>
      colorScheme.brightness == Brightness.dark ? _e1Dark : _e1Light;

  static List<BoxShadow> e1(BuildContext context) => e1Of(context.colorScheme);

  static List<BoxShadow> e2(BuildContext context) => e2Of(context.colorScheme);

  static List<BoxShadow> e2Of(ColorScheme colorScheme) =>
      colorScheme.brightness == Brightness.dark ? _e2Dark : _e2Light;

  static BoxShadow _shadow(
    int alpha,
    double y,
    double cssBlur, [
    double spread = 0,
  ]) => BoxShadow(
    color: Color.fromARGB(alpha, 0, 0, 0),
    offset: Offset(0, y),
    blurRadius: _blur(cssBlur),
    spreadRadius: spread,
  );

  static double _blur(double cssBlur) =>
      cssBlur <= 1 ? 0 : (cssBlur / 2 - 0.5) / 0.57735;

  static final _e1Light = [
    _shadow(0x0D, 0.5, 1),
    _shadow(0x0A, 2, 6),
    _shadow(0x17, 12, 32, -6),
  ];

  static final _e1Dark = [_shadow(0x80, 1, 2), _shadow(0x8C, 10, 28, -6)];

  static final _e2Light = [
    _shadow(0x0F, 1, 3),
    _shadow(0x14, 10, 24),
    _shadow(0x38, 32, 64, -12),
  ];

  static final _e2Dark = [_shadow(0x80, 2, 6), _shadow(0xB3, 32, 64, -12)];
}

/// Off the [AppCorner] scale: a dashboard card is taller than any other
/// surface in the app and keeps a larger corner than a sheet.
abstract final class DashboardCorner {
  static const desktopCard = 32.0;
  static const mobileCard = 34.0;
  static const block = 20.0;
  static const mobileBlock = 22.0;
  static const tab = 16.0;
  static const tableHeader = 12.0;
  static const badge = 14.0;
}

/// English thousands grouping, as `NumberFormat.decimalPattern('en')` prints
/// it. A dashboard figure is formatted once per poll tick per visible slot, and
/// the general pattern parser is an order of magnitude more work than the three
/// steps a grouped integer actually needs.
String _grouped(int count) {
  final digits = '$count';
  final length = digits.length;
  if (length < 4) {
    return digits;
  }
  final buffer = StringBuffer(digits[0]);
  for (var i = 1; i < length; i++) {
    if ((length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Grouped digits, as the design shows them, until they outgrow a third of a
/// phone's width.
String dashboardCount(int count) =>
    count < 100000 ? _grouped(count) : count.compact;

String dashboardTraffic(num bytes) {
  final show = bytes.traffic;
  return '${show.value} ${show.unit}';
}

/// The dashboard's text roles; every figure reads in tabular digits.
abstract final class DashboardText {
  static TextStyle cardTitle(BuildContext context) => AppTextStyle.footnote
      .of(context, emphasized: true)
      .copyWith(color: context.colorScheme.onSurfaceVariant);

  static TextStyle mobileCardTitle(BuildContext context) =>
      AppTextStyle.subheadline.of(context, emphasized: true);

  static TextStyle label(BuildContext context, {Color? color}) => AppTextStyle
      .caption1
      .of(context)
      .toTabular
      .copyWith(color: color ?? context.colorScheme.onSurfaceVariant);

  static TextStyle figure(
    BuildContext context,
    AppTextStyle style, {
    Color? color,
  }) => style
      .of(context, emphasized: true)
      .toTabular
      .copyWith(color: color, letterSpacing: -0.02 * style.size);

  /// The figure of a slot that lets the digits own their width, tracking
  /// included: the two [copyWith]s an open tracker "flattens" back to zero go.
  static TextStyle flatFigure(
    BuildContext context,
    AppTextStyle style, {
    Color? color,
  }) => style.of(context, emphasized: true).toTabular.copyWith(color: color);

  static TextStyle unit(
    BuildContext context, [
    AppTextStyle style = AppTextStyle.subheadline,
  ]) => style
      .of(context, emphasized: true)
      .copyWith(color: context.colorScheme.onSurfaceVariant);

  static TextStyle rowTitle(BuildContext context) =>
      AppTextStyle.subheadline.of(context, emphasized: true);
}
