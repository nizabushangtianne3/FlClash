import 'package:flutter/widgets.dart';

import 'context.dart';

extension DateTimeExtension on DateTime {
  bool get isBeforeNow {
    return isBefore(DateTime.now());
  }

  bool isBeforeSecure(DateTime? dateTime) {
    if (dateTime == null) {
      return false;
    }
    return true;
  }

  String getLastUpdateTimeDesc(BuildContext context, {bool compact = false}) {
    final appLocalizations = context.appLocalizations;
    if (year <= 1970) {
      return appLocalizations.unknown;
    }
    final (yearsAgo, monthsAgo, daysAgo, hoursAgo, minutesAgo) = compact
        ? (
            appLocalizations.yearsAgoShort,
            appLocalizations.monthsAgoShort,
            appLocalizations.daysAgoShort,
            appLocalizations.hoursAgoShort,
            appLocalizations.minutesAgoShort,
          )
        : (
            appLocalizations.yearsAgo,
            appLocalizations.monthsAgo,
            appLocalizations.daysAgo,
            appLocalizations.hoursAgo,
            appLocalizations.minutesAgo,
          );
    final currentDateTime = DateTime.now();
    final difference = currentDateTime.difference(this);
    final days = difference.inDays;
    if (days >= 365) {
      final years = (days / 365).floor();
      return yearsAgo(years);
    }
    if (days >= 30) {
      final months = (days / 30).floor();
      return monthsAgo(months);
    }
    if (days >= 1) {
      return daysAgo(days);
    }
    final hours = difference.inHours;
    if (hours >= 1) {
      return hoursAgo(hours);
    }
    final minutes = difference.inMinutes;
    if (minutes >= 1) {
      return minutesAgo(minutes);
    }
    return appLocalizations.justNow;
  }

  String get show {
    final local = isUtc ? toLocal() : this;
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  String get showFull {
    final local = isUtc ? toLocal() : this;
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute:$second';
  }

  String get showTime {
    final local = isUtc ? toLocal() : this;
    return ' ${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }
}

String getDateStringLast2(int value) {
  final valueRaw = '0$value';
  return valueRaw.substring(valueRaw.length - 2);
}

String getTimeText(int? timeStamp) {
  if (timeStamp == null) {
    return '00:00:00';
  }
  final diff = timeStamp / 1000;
  final inHours = (diff / 3600).floor();
  if (inHours > 999) {
    return '999:59:59';
  }
  final inMinutes = (diff / 60 % 60).floor();
  final inSeconds = (diff % 60).floor();
  final hoursText = inHours.toString().padLeft(2, '0');

  return '$hoursText:${getDateStringLast2(inMinutes)}:${getDateStringLast2(inSeconds)}';
}
