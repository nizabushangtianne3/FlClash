import 'package:fl_clash/features/connection/tracker_info_list.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('notifies for dynamic and static tracker changes', () {
    final controller = TrackerInfoListController();
    addTearDown(controller.dispose);
    controller.setTrackerInfos([_tracker('a')]);
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.setTrackerInfos([_tracker('a', upload: 10)]);
    controller.setTrackerInfos([
      _tracker('a', upload: 10, metadata: const Metadata(network: 'changed')),
    ]);

    expect(notifications, 2);
  });
}
