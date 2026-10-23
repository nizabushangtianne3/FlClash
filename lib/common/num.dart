import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/common.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:material_ui/material_ui.dart';

/// Pinned to English so every locale reads K and M, never 万 or тыс.
final _compactFormat = NumberFormat.compact(locale: 'en');

extension NumExt on num {
  String get compact => _compactFormat.format(this);

  String fixed({int decimals = 2}) {
    final formatted = toStringAsFixed(decimals);
    final dot = formatted.indexOf('.');
    if (dot < 0) {
      return formatted;
    }
    var end = formatted.length;
    while (end > dot + 1 && formatted.codeUnitAt(end - 1) == 0x30) {
      end--;
    }
    if (end == dot + 1) {
      end = dot;
    }
    return end == formatted.length ? formatted : formatted.substring(0, end);
  }

  TrafficShow get traffic {
    const units = TrafficUnit.values;
    var size = toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return TrafficShow(
      value: size.fixed(decimals: 1),
      unit: units[unitIndex].name,
    );
  }

  TrafficShow get shortTraffic {
    const units = TrafficUnit.values;
    var size = toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return TrafficShow(
      value: size.toStringAsFixed(0),
      unit: ' ${units[unitIndex].name}',
    );
  }
}

extension DoubleExt on double {
  bool moreOrEqual(double value) {
    return this > value || (value - this).abs() < precisionErrorTolerance;
  }
}

extension OffsetExt on Offset {
  double getCrossAxisOffset(Axis direction) {
    return direction == Axis.vertical ? dx : dy;
  }

  double getMainAxisOffset(Axis direction) {
    return direction == Axis.vertical ? dy : dx;
  }
}
