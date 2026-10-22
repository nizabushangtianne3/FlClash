import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selection changes reuse the filtered package list', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(packagesProvider.notifier).value = const [
      Package(
        packageName: 'com.example.beta',
        label: 'Beta',
        system: false,
        internet: true,
        lastUpdateTime: 1,
      ),
      Package(
        packageName: 'com.example.alpha',
        label: 'Alpha',
        system: false,
        internet: true,
        lastUpdateTime: 2,
      ),
    ];
    container
        .read(accessControlStateProvider.notifier)
        .value = const AccessControlProps(
      enable: true,
      sort: AccessSortType.name,
      isFilterSystemApp: false,
      isFilterNonInternetApp: false,
    );

    final provider = accessViewPackagesProvider(const []);
    container.listen(provider, (_, _) {});
    final first = container.read(provider);

    container
        .read(accessControlStateProvider.notifier)
        .update((state) => state.copyWith(rejectList: ['com.example.beta']));
    final second = container.read(provider);
    expect(identical(first, second), isTrue);

    container
        .read(accessControlStateProvider.notifier)
        .update((state) => state.copyWith(sort: AccessSortType.time));
    final third = container.read(provider);
    expect(identical(first, third), isFalse);
    expect(third.packages.map((item) => item.packageName), [
      'com.example.alpha',
      'com.example.beta',
    ]);
  });
}
