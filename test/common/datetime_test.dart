import 'package:fl_clash/common/common.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  group('DateTimeExtension.localMoment', () {
    test('renders a UTC moment as the local time it is', () {
      final utc = DateTime.utc(2026, 5, 27, 13, 45, 30);

      expect(utc.isUtc, isTrue);
      expect(utc.localMoment.isUtc, isFalse);
      expect(utc.localMoment.year, 2026);
      expect(utc.localMoment, utc.toLocal());
    });

    test('hands back a local moment untouched', () {
      final local = DateTime(2026, 5, 27, 13, 45, 30);

      expect(local.localMoment, same(local));
    });

    test('reads the rendered text of a moment the same way every time', () {
      final utc = DateTime.utc(2026, 5, 27, 13, 45, 30);
      final localOfUtc = utc.toLocal();

      expect(utc.show, localOfUtc.show);
      expect(utc.showTime, localOfUtc.showTime);
      expect(utc.showFull, localOfUtc.showFull);
      // A second read of the same moment is the same string, not a new one.
      expect(utc.showTime, same(utc.showTime));
      expect(utc.showFull, same(utc.showFull));
      expect(utc.show, same(utc.show));
    });

    test('a moment one second off is not the same text', () {
      final utc = DateTime.utc(2026, 5, 27, 13, 45, 30);
      final later = utc.add(const Duration(seconds: 1));

      expect(later.showTime, isNot(same(utc.showTime)));
    });
  });

  group('DateTimeExtension', () {
    test('detects dates before now', () {
      expect(
        DateTime.now().subtract(const Duration(milliseconds: 1)).isBeforeNow,
        isTrue,
      );
    });

    test('isBeforeSecure keeps null as false and non-null as true', () {
      final dateTime = DateTime(2026, 5, 27);

      expect(dateTime.isBeforeSecure(null), isFalse);
      expect(dateTime.isBeforeSecure(DateTime(2026, 5, 26)), isTrue);
      expect(dateTime.isBeforeSecure(DateTime(2026, 5, 28)), isTrue);
    });

    test('formats date, full datetime, and time slices', () {
      final dateTime = DateTime(2026, 5, 27, 14, 3, 9);

      expect(dateTime.show, '2026-05-27');
      expect(dateTime.showFull, '2026-05-27 14:03:09');
      expect(dateTime.showTime, ' 14:03:09');
    });

    test('formats offset timestamps in the system time zone', () {
      final parsed = DateTime.parse('2026-05-27T14:03:09+08:00');
      final local = DateTime.fromMillisecondsSinceEpoch(
        parsed.millisecondsSinceEpoch,
      );

      expect(parsed.isUtc, isTrue);
      expect(parsed.showFull, local.toString().substring(0, 19));
      expect(parsed.show, local.toString().substring(0, 10));
    });

    testWidgets(
      'getLastUpdateTimeDesc returns unknown for epoch or year <= 1970',
      (tester) async {
        late BuildContext buildContext;
        await tester.pumpWidget(
          TestApp(
            child: Builder(
              builder: (context) {
                buildContext = context;
                return const SizedBox();
              },
            ),
          ),
        );

        final epochZero = DateTime.fromMillisecondsSinceEpoch(0);
        final year1970 = DateTime.utc(1970, 1, 1);
        final year1 = DateTime.utc(1, 1, 1);

        final l10n = buildContext.appLocalizations;
        expect(epochZero.getLastUpdateTimeDesc(buildContext), l10n.unknown);
        expect(year1970.getLastUpdateTimeDesc(buildContext), l10n.unknown);
        expect(year1.getLastUpdateTimeDesc(buildContext), l10n.unknown);
      },
    );

    testWidgets(
      'getLastUpdateTimeDesc returns relative times for valid dates',
      (tester) async {
        late BuildContext buildContext;
        await tester.pumpWidget(
          TestApp(
            child: Builder(
              builder: (context) {
                buildContext = context;
                return const SizedBox();
              },
            ),
          ),
        );

        final l10n = buildContext.appLocalizations;
        final now = DateTime.now();

        expect(now.getLastUpdateTimeDesc(buildContext), l10n.justNow);
        expect(
          now
              .subtract(const Duration(minutes: 5))
              .getLastUpdateTimeDesc(buildContext),
          l10n.minutesAgo(5),
        );
        expect(
          now
              .subtract(const Duration(hours: 3))
              .getLastUpdateTimeDesc(buildContext),
          l10n.hoursAgo(3),
        );
        expect(
          now
              .subtract(const Duration(days: 4))
              .getLastUpdateTimeDesc(buildContext),
          l10n.daysAgo(4),
        );
        expect(
          now
              .subtract(const Duration(minutes: 5))
              .getLastUpdateTimeDesc(buildContext, compact: true),
          '5m ago',
        );
        expect(
          now
              .subtract(const Duration(days: 60))
              .getLastUpdateTimeDesc(buildContext, compact: true),
          '2mo ago',
        );
      },
    );
  });
}
