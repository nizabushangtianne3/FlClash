import 'package:fl_clash/common/compute.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  group('computeRealSelectedProxyState', () {
    test('returns state unchanged when proxyName is empty', () {
      final state = computeRealSelectedProxyState(
        '',
        groups: [],
        selectedMap: {},
      );
      expect(state.proxyName, '');
      expect(state.group, false);
    });

    test('resolves to leaf proxy not in any group', () {
      final state = computeRealSelectedProxyState(
        'proxy-a',
        groups: [],
        selectedMap: {},
      );
      expect(state.proxyName, 'proxy-a');
      expect(state.group, true);
    });

    test('resolves single-hop chain via selectedMap', () {
      final groups = [
        const Group(
          name: 'auto',
          type: GroupType.URLTest,
          all: [
            Proxy(name: 'proxy-a', type: 'ss'),
            Proxy(name: 'proxy-b', type: 'ss'),
          ],
        ),
      ];
      final selectedMap = {'auto': 'proxy-a'};
      final state = computeRealSelectedProxyState(
        'auto',
        groups: groups,
        selectedMap: selectedMap,
      );
      expect(state.proxyName, 'proxy-a');
      expect(state.group, true);
      expect(state.testUrl, isNull);
    });

    test('resolves multi-hop chain', () {
      final groups = [
        const Group(
          name: 'group-a',
          type: GroupType.Selector,
          testUrl: 'http://test-a.com',
          all: [
            Proxy(name: 'group-b', type: 'ss'),
            Proxy(name: 'proxy-x', type: 'ss'),
          ],
        ),
        const Group(
          name: 'group-b',
          type: GroupType.URLTest,
          testUrl: 'http://test-b.com',
          all: [Proxy(name: 'proxy-leaf', type: 'ss')],
        ),
      ];
      final selectedMap = {'group-a': 'group-b', 'group-b': 'proxy-leaf'};
      final state = computeRealSelectedProxyState(
        'group-a',
        groups: groups,
        selectedMap: selectedMap,
      );
      expect(state.proxyName, 'proxy-leaf');
      expect(state.group, true);
      expect(state.testUrl, 'http://test-b.com');
    });

    test('stops at group when selectedMap has no entry', () {
      final groups = [
        const Group(
          name: 'group-a',
          type: GroupType.Selector,
          all: [Proxy(name: 'proxy-a', type: 'ss')],
        ),
      ];
      final state = computeRealSelectedProxyState(
        'group-a',
        groups: groups,
        selectedMap: {},
      );
      expect(state.proxyName, 'group-a');
      expect(state.group, true);
    });

    test('URLTest group prefers realNow over selectedMap value', () {
      final groups = [
        const Group(
          name: 'auto',
          type: GroupType.URLTest,
          now: 'proxy-fast',
          all: [
            Proxy(name: 'proxy-fast', type: 'ss'),
            Proxy(name: 'proxy-slow', type: 'ss'),
          ],
        ),
      ];
      final state = computeRealSelectedProxyState(
        'auto',
        groups: groups,
        selectedMap: {'auto': 'proxy-slow'},
      );
      expect(state.proxyName, 'proxy-fast');
    });

    test('Selector group prefers selectedMap value over realNow', () {
      final groups = [
        const Group(
          name: 'selector',
          type: GroupType.Selector,
          now: 'proxy-a',
          all: [
            Proxy(name: 'proxy-a', type: 'ss'),
            Proxy(name: 'proxy-b', type: 'ss'),
          ],
        ),
      ];
      final state = computeRealSelectedProxyState(
        'selector',
        groups: groups,
        selectedMap: {'selector': 'proxy-b'},
      );
      expect(state.proxyName, 'proxy-b');
    });

    test('duplicate group names keep the first group', () {
      final groups = [
        const Group(
          name: 'duplicate',
          type: GroupType.URLTest,
          now: 'first',
          all: [Proxy(name: 'first', type: 'ss')],
        ),
        const Group(
          name: 'duplicate',
          type: GroupType.URLTest,
          now: 'second',
          all: [Proxy(name: 'second', type: 'ss')],
        ),
      ];

      final state = computeRealSelectedProxyState(
        'duplicate',
        groups: groups,
        selectedMap: {},
      );

      expect(state.proxyName, 'first');
    });
  });

  group('computeProxyDelayState', () {
    test('returns delay from delayMap for resolved proxy', () {
      final groups = [
        const Group(
          name: 'auto',
          type: GroupType.URLTest,
          all: [Proxy(name: 'proxy-a', type: 'ss')],
        ),
      ];
      final delayMap = <String, Map<String, int?>>{
        'http://test.com': {'proxy-a': 120},
      };
      final state = computeProxyDelayState(
        proxyName: 'auto',
        testUrl: 'http://test.com',
        groups: groups,
        selectedMap: {'auto': 'proxy-a'},
        delayMap: delayMap,
      );
      expect(state.delay, 120);
      expect(state.group, true);
    });

    test('returns delay 0 when proxy not found in delayMap', () {
      final state = computeProxyDelayState(
        proxyName: 'proxy-x',
        testUrl: 'http://test.com',
        groups: [],
        selectedMap: {},
        delayMap: {},
      );
      expect(state.delay, 0);
    });

    test('uses group testUrl over default when available', () {
      final groups = [
        const Group(
          name: 'auto',
          type: GroupType.URLTest,
          testUrl: 'http://group-test.com',
          all: [Proxy(name: 'proxy-a', type: 'ss')],
        ),
      ];
      final delayMap = <String, Map<String, int?>>{
        'http://group-test.com': {'proxy-a': 50},
      };
      final state = computeProxyDelayState(
        proxyName: 'auto',
        testUrl: 'http://default.com',
        groups: groups,
        selectedMap: {'auto': 'proxy-a'},
        delayMap: delayMap,
      );
      expect(state.delay, 50);
    });

    test('falls back to default testUrl when group has no testUrl', () {
      final groups = [
        const Group(
          name: 'auto',
          type: GroupType.URLTest,
          all: [Proxy(name: 'proxy-a', type: 'ss')],
        ),
      ];
      final delayMap = <String, Map<String, int?>>{
        'http://default.com': {'proxy-a': 80},
      };
      final state = computeProxyDelayState(
        proxyName: 'auto',
        testUrl: 'http://default.com',
        groups: groups,
        selectedMap: {'auto': 'proxy-a'},
        delayMap: delayMap,
      );
      expect(state.delay, 80);
    });

    test('uses the group map to resolve a proxy', () {
      const group = Group(
        name: 'auto',
        type: GroupType.URLTest,
        all: [Proxy(name: 'proxy-a', type: 'ss')],
      );
      final state = computeProxyDelayState(
        proxyName: 'auto',
        testUrl: 'http://test.com',
        groups: [],
        selectedMap: {'auto': 'proxy-a'},
        delayMap: {
          'http://test.com': {'proxy-a': 70},
        },
        groupsByName: {'auto': group},
      );
      expect(state.delay, 70);
      expect(state.group, true);
    });
  });

  group('computeSort', () {
    late List<Group> groups;
    late DelayMap delayMap;

    setUp(() {
      groups = [
        const Group(
          name: 'proxies',
          type: GroupType.Selector,
          all: [
            Proxy(name: 'proxy-c', type: 'ss'),
            Proxy(name: 'proxy-a', type: 'ss'),
            Proxy(name: 'proxy-b', type: 'ss'),
          ],
        ),
      ];
      delayMap = <String, Map<String, int?>>{
        'http://test.com': {'proxy-a': 100, 'proxy-b': 50, 'proxy-c': 0},
      };
    });

    test('ProxiesSortType.none preserves original order', () {
      final result = computeSort(
        groups: groups,
        sortType: ProxiesSortType.none,
        delayMap: delayMap,
        selectedMap: {},
        defaultTestUrl: 'http://test.com',
      );
      expect(result[0].all.map((p) => p.name).toList(), [
        'proxy-c',
        'proxy-a',
        'proxy-b',
      ]);
    });

    test('ProxiesSortType.name sorts alphabetically', () {
      final result = computeSort(
        groups: groups,
        sortType: ProxiesSortType.name,
        delayMap: delayMap,
        selectedMap: {},
        defaultTestUrl: 'http://test.com',
      );
      expect(result[0].all.map((p) => p.name).toList(), [
        'proxy-a',
        'proxy-b',
        'proxy-c',
      ]);
    });

    test('ProxiesSortType.delay sorts by delay value', () {
      final result = computeSort(
        groups: groups,
        sortType: ProxiesSortType.delay,
        delayMap: delayMap,
        selectedMap: {},
        defaultTestUrl: 'http://test.com',
      );
      final names = result[0].all.map((p) => p.name).toList();
      expect(names.indexOf('proxy-b'), lessThan(names.indexOf('proxy-a')));
    });

    test('preserves group count in result', () {
      final multiGroups = [
        ...groups,
        const Group(
          name: 'other',
          type: GroupType.Selector,
          all: [Proxy(name: 'p1', type: 'ss')],
        ),
      ];
      final result = computeSort(
        groups: multiGroups,
        sortType: ProxiesSortType.none,
        delayMap: {},
        selectedMap: {},
        defaultTestUrl: '',
      );
      expect(result.length, 2);
    });

    test('resolves the same proxy once while sorting multiple groups', () {
      const proxyA = Proxy(name: 'proxy-a', type: 'ss');
      const proxyB = Proxy(name: 'proxy-b', type: 'ss');
      const groupA = Group(
        name: 'group-a',
        type: GroupType.Selector,
        testUrl: 'http://a.test',
        all: [proxyA, proxyB],
      );
      const groupB = Group(
        name: 'group-b',
        type: GroupType.Selector,
        testUrl: 'http://b.test',
        all: [proxyA, proxyB],
      );
      final result = computeSort(
        groups: [groupA, groupB],
        sortType: ProxiesSortType.delay,
        delayMap: {
          'http://a.test': {'proxy-a': 100, 'proxy-b': 50},
          'http://b.test': {'proxy-a': 80, 'proxy-b': 90},
        },
        selectedMap: {},
        defaultTestUrl: 'http://default.test',
      );
      expect(result[0].all.map((p) => p.name).toList(), ['proxy-b', 'proxy-a']);
      expect(result[1].all.map((p) => p.name).toList(), ['proxy-a', 'proxy-b']);
    });

    test('keeps the source groups when sorting does not change the order', () {
      const proxyA = Proxy(name: 'proxy-a', type: 'ss');
      const proxyB = Proxy(name: 'proxy-b', type: 'ss');
      const group = Group(
        name: 'group-a',
        type: GroupType.Selector,
        testUrl: 'http://a.test',
        all: [proxyA, proxyB],
      );
      final result = computeSort(
        groups: [group],
        sortType: ProxiesSortType.delay,
        delayMap: {
          'http://a.test': {'proxy-a': 50, 'proxy-b': 100},
        },
        selectedMap: {},
        defaultTestUrl: 'http://default.test',
      );
      expect(identical(result.single, group), isTrue);
      expect(result.single.all.map((proxy) => proxy.name).toList(), [
        'proxy-a',
        'proxy-b',
      ]);
    });

    test('keeps large equal-delay groups in configuration order', () {
      final proxies = [
        for (var index = 0; index < 64; index++)
          Proxy(name: 'proxy-${index.toString().padLeft(2, '0')}', type: 'ss'),
      ];
      final group = Group(
        name: 'group-a',
        type: GroupType.Selector,
        testUrl: 'http://a.test',
        all: proxies,
      );
      final result = computeSort(
        groups: [group],
        sortType: ProxiesSortType.delay,
        delayMap: {
          'http://a.test': {for (final proxy in proxies) proxy.name: 50},
        },
        selectedMap: {},
        defaultTestUrl: 'http://default.test',
      );
      expect(identical(result.single, group), isTrue);
      expect(
        result.single.all.map((proxy) => proxy.name).toList(),
        proxies.map((proxy) => proxy.name).toList(),
      );
    });

    test('re-sorting an already ordered group keeps its identity', () {
      const proxyA = Proxy(name: 'proxy-a', type: 'ss');
      const proxyB = Proxy(name: 'proxy-b', type: 'ss');
      const group = Group(
        name: 'group-a',
        type: GroupType.Selector,
        testUrl: 'http://a.test',
        all: [proxyA, proxyB],
      );
      final delayMap = {
        'http://a.test': {'proxy-a': 100, 'proxy-b': 50},
      };
      final first = computeSort(
        groups: [group],
        sortType: ProxiesSortType.delay,
        delayMap: delayMap,
        selectedMap: {},
        defaultTestUrl: 'http://default.test',
      );
      expect(first.single.all.map((proxy) => proxy.name).toList(), [
        'proxy-b',
        'proxy-a',
      ]);
      final second = computeSort(
        groups: first,
        sortType: ProxiesSortType.delay,
        delayMap: delayMap,
        selectedMap: {},
        defaultTestUrl: 'http://default.test',
      );
      expect(identical(second, first), isTrue);
    });
  });

  group('Group.getCurrentSelectedName', () {
    test('URLTest group returns realNow when non-empty', () {
      const group = Group(
        name: 'auto',
        type: GroupType.URLTest,
        now: 'proxy-fast',
      );
      expect(group.getCurrentSelectedName('proxy-input'), 'proxy-fast');
    });

    test('URLTest group falls back to proxyName when now is null', () {
      const group = Group(name: 'auto', type: GroupType.URLTest);
      expect(group.getCurrentSelectedName('proxy-input'), 'proxy-input');
    });

    test('URLTest group returns empty when both now and proxyName empty', () {
      const group = Group(name: 'auto', type: GroupType.URLTest);
      expect(group.getCurrentSelectedName(''), '');
    });

    test('Selector group returns proxyName when non-empty', () {
      const group = Group(
        name: 'sel',
        type: GroupType.Selector,
        now: 'proxy-now',
      );
      expect(group.getCurrentSelectedName('proxy-selected'), 'proxy-selected');
    });

    test('Selector group falls back to realNow when proxyName empty', () {
      const group = Group(
        name: 'sel',
        type: GroupType.Selector,
        now: 'proxy-now',
      );
      expect(group.getCurrentSelectedName(''), 'proxy-now');
    });

    test('Selector group returns empty when both empty', () {
      const group = Group(name: 'sel', type: GroupType.Selector);
      expect(group.getCurrentSelectedName(''), '');
    });
  });

  group('computeHideTimeout', () {
    const defaultTestUrl = 'https://default.test';

    List<Group> hide({
      required List<Group> groups,
      required DelayMap delayMap,
      Map<String, String> selectedMap = const {},
    }) {
      return computeHideTimeout(
        groups: groups,
        allGroups: groups,
        delayMap: delayMap,
        selectedMap: selectedMap,
        defaultTestUrl: defaultTestUrl,
      );
    }

    const group = Group(
      name: 'sel',
      type: GroupType.Selector,
      all: [
        Proxy(name: 'fast', type: 'ss'),
        Proxy(name: 'slow', type: 'ss'),
        Proxy(name: 'untested', type: 'ss'),
      ],
    );

    test('drops the proxies whose last probe timed out', () {
      final groups = hide(
        groups: [group],
        delayMap: {
          defaultTestUrl: {'fast': 120, 'slow': -1},
        },
      );
      expect(groups.single.all.map((proxy) => proxy.name), [
        'fast',
        'untested',
      ]);
    });

    test('keeps a timed-out proxy while it is the selected one', () {
      final groups = hide(
        groups: [group],
        delayMap: {
          defaultTestUrl: {'slow': -1},
        },
        selectedMap: {'sel': 'slow'},
      );
      expect(groups.single.all.map((proxy) => proxy.name), [
        'fast',
        'slow',
        'untested',
      ]);
    });

    test('keeps built-in adapters a delay probe cannot reach', () {
      const withBuiltins = Group(
        name: 'sel',
        type: GroupType.Selector,
        all: [
          Proxy(name: 'slow', type: 'ss'),
          Proxy(name: 'REJECT', type: 'Reject'),
          Proxy(name: 'PASS', type: 'Pass'),
          Proxy(name: 'blocked', type: 'Selector'),
        ],
      );
      const blocked = Group(
        name: 'blocked',
        type: GroupType.Selector,
        all: [Proxy(name: 'REJECT', type: 'Reject')],
      );
      final groups = hide(
        groups: [withBuiltins, blocked],
        delayMap: {
          defaultTestUrl: {'slow': -1, 'REJECT': -1, 'PASS': -1},
        },
      );
      expect(groups.first.all.map((proxy) => proxy.name), [
        'REJECT',
        'PASS',
        'blocked',
      ]);
    });

    test('keeps the source groups when no proxy is hidden', () {
      final groups = hide(
        groups: [group],
        delayMap: {},
      );
      expect(identical(groups.single, group), isTrue);
      expect(groups.single.all.map((proxy) => proxy.name), [
        'fast',
        'slow',
        'untested',
      ]);
    });

    test("reads a group's own test url", () {
      const withTestUrl = Group(
        name: 'sel',
        type: GroupType.Selector,
        testUrl: 'https://group.test',
        all: [
          Proxy(name: 'fast', type: 'ss'),
          Proxy(name: 'slow', type: 'ss'),
        ],
      );
      expect(
        hide(
          groups: [withTestUrl],
          delayMap: {
            defaultTestUrl: {'slow': -1},
          },
        ).single.all,
        hasLength(2),
      );
      expect(
        hide(
          groups: [withTestUrl],
          delayMap: {
            'https://group.test': {'slow': -1},
          },
        ).single.all.map((proxy) => proxy.name),
        ['fast'],
      );
    });
  });
}
