import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/manager/app_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ProxiesRefreshState state({
    bool isProxies = false,
    int sortNum = 0,
    ProxiesSortType sortType = ProxiesSortType.none,
  }) {
    return (isProxies: isProxies, sortNum: sortNum, sortType: sortType);
  }

  test('refreshes the tree when entering the proxies page', () {
    expect(needsProxiesRefresh(state(), state(isProxies: true)), isTrue);
  });

  test('refreshes the tree for sort changes made off the page', () {
    expect(needsProxiesRefresh(state(sortNum: 1), state(sortNum: 2)), isTrue);
    expect(
      needsProxiesRefresh(
        state(sortType: ProxiesSortType.name),
        state(sortType: ProxiesSortType.delay),
      ),
      isTrue,
    );
  });

  test('skips the tree refresh when only leaving the proxies page', () {
    expect(needsProxiesRefresh(state(isProxies: true), state()), isFalse);
  });

  test('skips unchanged and uninitialized states', () {
    expect(needsProxiesRefresh(null, state()), isFalse);
    expect(needsProxiesRefresh(state(), state()), isFalse);
  });
}
