import 'package:fl_clash/features/connection/tracker_info_list.dart';
import 'package:fl_clash/features/connection/tracker_info_item.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

TrackerInfo _tracker(
  String id, {
  int upload = 0,
  int download = 0,
  Metadata metadata = const Metadata(),
}) {
  return TrackerInfo(
    id: id,
    upload: upload,
    download: download,
    start: DateTime.utc(2026),
    metadata: metadata,
    chains: const [],
    rule: 'MATCH',
    rulePayload: '',
  );
}

void main() {
  test('reuses rows when the same tracker objects are republished', () {
    final controller = TrackerInfoListController();
    addTearDown(controller.dispose);
    final first = _tracker('a');
    final second = _tracker('b');

    controller.setTrackerInfos([first, second]);
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.setTrackerInfos([first, second]);

    expect(notifications, 0);
  });

  test(
    'notifies for dynamic changes and ignores republished static fields',
    () {
      final controller = TrackerInfoListController();
      addTearDown(controller.dispose);
      controller.setTrackerInfos([_tracker('a')]);
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.setTrackerInfos([_tracker('a', upload: 10)]);
      controller.setTrackerInfos([
        _tracker('a', upload: 10, metadata: const Metadata(network: 'changed')),
      ]);

      expect(notifications, 1);
    },
  );

  testWidgets('a poll that republishes the same ids keeps the rows', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    globalState.container = container;

    Future<void> pump(List<TrackerInfo> trackerInfos) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TestApp(
            child: TrackerInfoAnimatedList(
              trackerInfos: trackerInfos,
              detailTitle: 'detail',
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pump([_tracker('a'), _tracker('b')]);
    expect(find.byType(TrackerInfoItem), findsNWidgets(2));

    await pump([_tracker('a', upload: 10), _tracker('b')]);
    expect(find.byType(TrackerInfoItem), findsNWidgets(2));

    await pump([_tracker('b')]);
    await tester.pumpAndSettle();
    expect(find.byType(TrackerInfoItem), findsOneWidget);
  });
}
