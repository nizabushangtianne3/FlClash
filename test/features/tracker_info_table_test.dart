import 'package:fl_clash/features/connection/tracker_info_table.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

TrackerInfo _tracker(DateTime start) {
  return TrackerInfo(
    id: start.toIso8601String(),
    start: start,
    metadata: const Metadata(),
    chains: const ['DIRECT'],
    rule: 'MATCH',
    rulePayload: '',
  );
}

void main() {
  testWidgets('live durations use the timestamp the caller provides', (
    tester,
  ) async {
    final now = DateTime.utc(2026).add(const Duration(minutes: 1));
    late BuildContext context;
    late List<RecordColumn<TrackerInfo>> columns;

    await tester.pumpWidget(
      TestApp(
        child: Builder(
          builder: (buildContext) {
            context = buildContext;
            columns = trackerInfoColumns(
              buildContext,
              width: 1300,
              isLive: true,
              now: now,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final duration = columns.singleWhere((column) => column.id == 'duration');
    final fiftyNineSeconds =
        duration.cell(
              context,
              _tracker(now.subtract(const Duration(seconds: 59))),
            )
            as RecordCellText;
    final oneMinute =
        duration.cell(
              context,
              _tracker(now.subtract(const Duration(minutes: 1))),
            )
            as RecordCellText;

    expect(fiftyNineSeconds.text, '59 s');
    expect(oneMinute.text, '1.0 min');
  });
}
