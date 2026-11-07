import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

typedef _Item = ({String id, String network, String app, List<String> tags});

final _facets = <RecordFacet<_Item>>[
  RecordFacet.single(
    RecordFacetKind.network,
    (item) => item.network,
    offered: true,
    order: const ['tcp', 'udp'],
  ),
  RecordFacet.single(RecordFacetKind.app, (item) => item.app),
  RecordFacet(RecordFacetKind.proxy, (item) => item.tags),
];

_Item _item(
  String id, {
  String network = 'tcp',
  String app = 'curl',
  List<String> tags = const [],
}) => (id: id, network: network, app: app, tags: tags);

List<String> _ids(Iterable<_Item> items) => [for (final item in items) item.id];

List<String> _layout(List<RecordGroup<_Item>> groups) => [
  for (final group in groups) '${group.key}: ${_ids(group.items).join(' ')}',
];

void main() {
  group('whereFilters', () {
    final items = [
      _item('a'),
      _item('b', network: 'udp'),
      _item('c', app: 'chrome'),
      _item('d', network: 'udp', app: 'chrome'),
    ];

    test('widens within a facet and narrows across facets', () {
      expect(
        _ids(
          items.whereFilters(_facets, const [
            RecordFilter(RecordFacetKind.network, 'tcp'),
            RecordFilter(RecordFacetKind.network, 'udp'),
          ]),
        ),
        ['a', 'b', 'c', 'd'],
      );
      expect(
        _ids(
          items.whereFilters(_facets, const [
            RecordFilter(RecordFacetKind.network, 'udp'),
            RecordFilter(RecordFacetKind.app, 'chrome'),
          ]),
        ),
        ['d'],
      );
    });

    test('ignores a filter on a facet the list lacks', () {
      expect(
        _ids(
          items.whereFilters(_facets, const [
            RecordFilter(RecordFacetKind.level, 'error'),
          ]),
        ),
        ['a', 'b', 'c', 'd'],
      );
    });
  });

  group('RecordFacet.optionsOf', () {
    test('lists the values present in their order', () {
      final options = _facets.first.optionsOf([
        _item('a', network: 'udp'),
        _item('b'),
      ]);
      expect(options, ['tcp', 'udp']);
    });

    test('keeps the most frequent values and every selected one', () {
      final facet = RecordFacet<_Item>(
        RecordFacetKind.app,
        (item) => [item.app],
      );
      final items = [
        for (var i = 0; i < 30; i++)
          for (var j = 0; j <= i; j++) _item('$i-$j', app: 'app$i'),
      ];
      final options = facet.optionsOf(items, selected: ['gone']);
      expect(options, hasLength(recordFacetMaxOptions + 1));
      expect(options, contains('gone'));
      expect(options, contains('app29'));
      expect(options, isNot(contains('app0')));
    });

    test('leaves out empty values', () {
      expect(_facets.last.optionsOf([_item('a', app: '')]), isEmpty);
    });
  });

  group('groupRecords', () {
    final items = [
      _item('a'),
      _item('b', app: 'chrome'),
      _item('c'),
      _item('d', app: 'chrome'),
      _item('e', app: 'git'),
    ];

    test('orders groups by the first item each shows', () {
      expect(_layout(groupRecords(items, (item) => item.app)), [
        'curl: a c',
        'chrome: b d',
        'git: e',
      ]);
    });

    test('a list shown bottom up leads with its newest group and item', () {
      expect(_layout(groupRecords(items, (item) => item.app, reverse: true)), [
        'git: e',
        'chrome: d b',
        'curl: c a',
      ]);
    });
  });

  group('a facet that reads one value', () {
    test('counts, orders and filters like the one that reads a list', () {
      final single = _facets.first;
      final listed = RecordFacet<_Item>(
        RecordFacetKind.network,
        (item) => [item.network],
        offered: true,
        order: const ['tcp', 'udp'],
      );
      final items = [
        _item('a', network: 'udp'),
        _item('b'),
        _item('c', network: 'udp'),
        _item('d', network: ''),
      ];
      const filters = [RecordFilter(RecordFacetKind.network, 'tcp')];

      expect(single.optionsOf(items), listed.optionsOf(items));
      expect(single.optionsOf(items), ['tcp', 'udp']);
      expect(_ids(items.whereFilters([single], filters)), ['b']);
      expect(_ids(items.whereFilters([listed], filters)), ['b']);
    });

    test('a facet that reads several counts each of them', () {
      final facet = _facets.last;
      final items = [
        _item('a', tags: const ['Tokyo', 'Proxy']),
        _item('b', tags: const ['Proxy']),
      ];

      expect(facet.optionsOf(items), ['Proxy', 'Tokyo']);
      expect(
        _ids(
          items.whereFilters(
            [facet],
            const [RecordFilter(RecordFacetKind.proxy, 'Tokyo')],
          ),
        ),
        ['a'],
      );
    });
  });
}
