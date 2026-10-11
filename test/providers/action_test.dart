import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/test_profiles.dart';

class _MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

class _RecordingProfilesAction extends ProfilesAction {
  final updated = <int>[];

  @override
  Future<void> updateProfileNow(
    Profile profile, {
    bool showLoading = false,
    Iterable<int> renameIn = const [],
    bool applyProfileState = true,
  }) async {
    updated.add(profile.id);
  }
}

class _PartiallyFailingProfilesAction extends _RecordingProfilesAction {
  _PartiallyFailingProfilesAction(this.failing);

  final Set<int> failing;

  @override
  Future<void> updateProfileNow(
    Profile profile, {
    bool showLoading = false,
    Iterable<int> renameIn = const [],
    bool applyProfileState = true,
  }) async {
    updated.add(profile.id);
    if (failing.contains(profile.id)) {
      throw Exception('subscription is down');
    }
  }
}

class _BlockingProfilesAction extends _RecordingProfilesAction {
  final release = Completer<void>();

  @override
  Future<void> updateProfileNow(
    Profile profile, {
    bool showLoading = false,
    Iterable<int> renameIn = const [],
    bool applyProfileState = true,
  }) async {
    updated.add(profile.id);
    await release.future;
  }
}

class _QueueingProfilesAction extends ProfilesAction {
  final gate = Completer<void>();
  final runs = <String>[];

  @override
  Future<void> updateProfileNow(
    Profile profile, {
    bool showLoading = false,
    Iterable<int> renameIn = const [],
    bool applyProfileState = true,
  }) async {
    runs.add(profile.label);
    if (runs.length == 1) {
      await gate.future;
    }
  }
}

class _StatefulQueueProfilesAction extends ProfilesAction {
  final gate = Completer<void>();
  final calls = <({bool applyProfileState, String label})>[];

  @override
  Future<void> updateProfileNow(
    Profile profile, {
    bool showLoading = false,
    Iterable<int> renameIn = const [],
    bool applyProfileState = true,
  }) async {
    calls.add((applyProfileState: applyProfileState, label: profile.label));
    if (calls.length == 1) {
      await gate.future;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await AppLocalizations.load(const Locale('en'));
  });

  group('ProfilesAction', () {
    test('only update state decides whether a sweep must run again', () {
      final profiles = [
        Profile.normal(label: 'One', url: 'https://example.com/a'),
        Profile.normal(label: 'Two', url: 'https://example.com/b'),
      ];

      expect(
        sameProfileUpdateState(profiles, [
          profiles.first.copyWith(
            label: 'Renamed',
            selectedMap: const {'Group': 'Proxy'},
          ),
          profiles.last,
        ]),
        isTrue,
        reason: 'a node switch is not a subscription change',
      );
      expect(
        sameProfileUpdateState(profiles, List.of(profiles.reversed)),
        isTrue,
      );
      expect(
        sameProfileUpdateState(profiles, [
          profiles.first.copyWith(url: 'https://example.com/changed'),
          profiles.last,
        ]),
        isFalse,
      );
      expect(
        sameProfileUpdateState(profiles, [...profiles, profiles.first]),
        isFalse,
      );
    });

    test('a completed download merges into the latest profile state', () {
      final original = Profile.normal(
        label: 'Old',
        url: 'https://example.com/old',
      );
      final current = original.copyWith(
        label: 'User name',
        url: 'https://example.com/user-edited',
        selectedMap: const {'Group': 'New node'},
        subscriptionInfo: const SubscriptionInfo(upload: 3, download: 4),
        lastUpdateDate: DateTime(2026, 10, 10),
      );
      final updated = original.copyWith(
        label: 'Server name',
        subscriptionInfo: const SubscriptionInfo(upload: 1, download: 2),
        lastUpdateDate: DateTime(2026, 10, 11),
      );

      final merged = mergeUpdatedProfile(
        original: original,
        current: current,
        updated: updated,
      );

      expect(merged.label, 'User name');
      expect(merged.url, current.url);
      expect(merged.selectedMap, current.selectedMap);
      expect(merged.subscriptionInfo, updated.subscriptionInfo);
      expect(merged.lastUpdateDate, updated.lastUpdateDate);

      final unchangedLabel = mergeUpdatedProfile(
        original: original,
        current: original,
        updated: updated,
      );
      expect(unchangedLabel.label, 'Server name');

      final requested = mergeRequestedProfile(
        requested: original,
        current: current,
      );
      expect(requested.subscriptionInfo, current.subscriptionInfo);
      expect(requested.lastUpdateDate, current.lastUpdateDate);
    });

    test('a download whose URL was replaced does not apply to the Core', () {
      final profile = Profile.normal(
        label: 'One',
        url: 'https://example.com/old',
      );
      final changed = profile.copyWith(url: 'https://example.com/new');

      expect(
        shouldApplyUpdatedProfile(
          downloaded: profile,
          latest: profile,
          currentProfileId: profile.id,
        ),
        isTrue,
      );
      expect(
        shouldApplyUpdatedProfile(
          downloaded: profile,
          latest: changed,
          currentProfileId: profile.id,
        ),
        isFalse,
      );
      expect(
        shouldApplyUpdatedProfile(
          downloaded: profile,
          latest: profile,
          currentProfileId: null,
        ),
        isFalse,
      );
    });

    test('a queued edit preserves changes made while it waits', () async {
      final original = Profile.normal(
        label: 'Old',
        url: 'https://example.com/old',
      );
      final edited = original.copyWith(
        label: 'Edited',
        url: 'https://example.com/edited',
      );
      final action = _StatefulQueueProfilesAction();
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([original])),
          profilesActionProvider.overrideWith(() => action),
        ],
      );
      addTearDown(container.dispose);
      final profilesAction = container.read(profilesActionProvider.notifier);
      final profiles =
          container.read(profilesProvider.notifier) as TestProfiles;

      final first = profilesAction.updateProfile(original);
      profiles.put(
        original.copyWith(selectedMap: const {'Group': 'Current node'}),
      );
      final second = profilesAction.updateProfile(edited);

      final queuedProfile = container.read(profilesProvider).single;
      expect(queuedProfile.label, 'Edited');
      expect(queuedProfile.url, edited.url);
      expect(queuedProfile.selectedMap, {'Group': 'Current node'});

      action.gate.complete();
      await Future.wait([first, second]);

      expect(action.calls.map((call) => call.applyProfileState), [true, false]);
      expect(action.calls.map((call) => call.label), ['Old', 'Edited']);
    });

    test('auto update sweeps only the subscriptions that are due', () async {
      final now = DateTime.now();
      final due = Profile(
        id: 1,
        url: 'https://example.com/a',
        autoUpdateDuration: const Duration(hours: 1),
        lastUpdateDate: now.subtract(const Duration(hours: 2)),
      );
      final later = Profile(
        id: 2,
        url: 'https://example.com/b',
        autoUpdateDuration: const Duration(hours: 6),
        lastUpdateDate: now,
      );
      final noInterval = Profile(
        id: 3,
        url: 'https://example.com/c',
        autoUpdateDuration: Duration.zero,
        lastUpdateDate: now.subtract(const Duration(hours: 2)),
      );
      final action = _RecordingProfilesAction();
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(
            () => TestProfiles([due, later, noInterval]),
          ),
          profilesActionProvider.overrideWith(() => action),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(profilesActionProvider.notifier)
          .autoUpdateProfiles();

      expect(action.updated, [due.id]);
    });

    test('auto update skips profiles waiting out a retry', () async {
      final now = DateTime.now();
      final due = Profile(
        id: 1,
        url: 'https://example.com/a',
        autoUpdateDuration: const Duration(hours: 1),
        lastUpdateDate: now.subtract(const Duration(hours: 2)),
      );
      final action = _RecordingProfilesAction();
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([due])),
          profilesActionProvider.overrideWith(() => action),
        ],
      );
      addTearDown(container.dispose);

      final failed = await container
          .read(profilesActionProvider.notifier)
          .autoUpdateProfiles(skipProfileIds: {due.id});

      expect(action.updated, isEmpty);
      expect(failed, isEmpty);
    });

    test('keeps edited profile data when remote update fails', () async {
      final original = Profile.normal(label: 'old label', url: 'bad-url');
      final edited = original.copyWith(
        label: 'new label',
        url: 'still-bad-url',
      );
      final container = ProviderContainer(
        overrides: [
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => TestProfiles([original])),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(profilesProvider).getProfile(original.id),
        original,
      );

      await expectLater(
        container.read(profilesActionProvider.notifier).updateProfile(edited),
        throwsA(anything),
      );

      final profile = container.read(profilesProvider).getProfile(original.id);
      expect(profile?.label, edited.label);
      expect(profile?.url, edited.url);
    });

    test('sweeps past a dead subscription and reports it', () async {
      final broken = Profile.normal(
        label: 'Broken',
        url: 'https://example.com/broken',
      );
      final healthy = Profile.normal(
        label: 'Healthy',
        url: 'https://example.com/ok',
      );
      final action = _PartiallyFailingProfilesAction({broken.id});
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([broken, healthy])),
          profilesActionProvider.overrideWith(() => action),
        ],
      );
      addTearDown(container.dispose);

      final messages = await container
          .read(profilesActionProvider.notifier)
          .updateProfiles();

      expect(action.updated, containsAll([broken.id, healthy.id]));
      expect(messages.map((message) => message.label), ['Broken']);
    });

    test('a second sweep joins the one already running', () async {
      final profile = Profile.normal(
        label: 'One',
        url: 'https://example.com/a',
      );
      final action = _BlockingProfilesAction();
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([profile])),
          profilesActionProvider.overrideWith(() => action),
        ],
      );
      addTearDown(container.dispose);
      final profilesAction = container.read(profilesActionProvider.notifier);

      final first = profilesAction.updateProfiles();
      final second = profilesAction.updateProfiles();

      expect(identical(first, second), isTrue);
      action.release.complete();
      await Future.wait([first, second]);
      expect(action.updated, [profile.id]);
    });

    test('a profile runs only the latest update waiting behind one', () async {
      const old = Profile(
        id: 1,
        label: 'old',
        autoUpdateDuration: Duration(hours: 1),
      );
      const middle = Profile(
        id: 1,
        label: 'middle',
        autoUpdateDuration: Duration(hours: 1),
      );
      const latest = Profile(
        id: 1,
        label: 'latest',
        autoUpdateDuration: Duration(hours: 1),
      );
      final action = _QueueingProfilesAction();
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([old])),
          profilesActionProvider.overrideWith(() => action),
        ],
      );
      addTearDown(container.dispose);
      final profilesAction = container.read(profilesActionProvider.notifier);

      final first = profilesAction.updateProfile(old);
      final second = profilesAction.updateProfile(middle);
      final third = profilesAction.updateProfile(latest);
      await Future<void>.delayed(Duration.zero);

      expect(action.runs, ['old']);

      action.gate.complete();
      await Future.wait([first, second, third]);

      expect(action.runs, ['old', 'latest']);
    });

    test('a sweep picks up a profile added while it runs', () async {
      final firstProfile = Profile.normal(
        label: 'One',
        url: 'https://example.com/a',
      );
      final addedProfile = Profile.normal(
        label: 'Two',
        url: 'https://example.com/b',
      );
      final action = _BlockingProfilesAction();
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([firstProfile])),
          profilesActionProvider.overrideWith(() => action),
        ],
      );
      addTearDown(container.dispose);
      final profilesAction = container.read(profilesActionProvider.notifier);
      final profiles =
          container.read(profilesProvider.notifier) as TestProfiles;

      final first = profilesAction.updateProfiles();
      profiles.put(addedProfile);
      final second = profilesAction.updateProfiles();

      expect(identical(first, second), isTrue);
      action.release.complete();
      await first;

      expect(action.updated, [
        firstProfile.id,
        firstProfile.id,
        addedProfile.id,
      ]);
    });

    test('updates selection, inserts first profile, and reorders profiles', () {
      final first = Profile.normal(label: 'First');
      final second = Profile.normal(label: 'Second');
      final container = ProviderContainer(
        overrides: [
          currentProfileIdProvider.overrideWithBuild((_, _) => first.id),
          profilesProvider.overrideWith(() => TestProfiles([first])),
        ],
      );
      addTearDown(container.dispose);
      final action = container.read(profilesActionProvider.notifier);

      action.updateCurrentSelectedMap('Group', 'Proxy');
      final updatedFirst = container.read(profilesProvider).single;
      expect(updatedFirst.selectedMap['Group'], 'Proxy');

      action.updateCurrentSelectedMap('Group', 'Proxy');
      expect(container.read(profilesProvider), hasLength(1));

      container.read(currentProfileIdProvider.notifier).value = null;
      action.putProfile(second);
      expect(container.read(currentProfileIdProvider), second.id);
      expect(container.read(profilesProvider), [updatedFirst, second]);

      action.reorder([second, updatedFirst]);
      expect(container.read(profilesProvider), [second, updatedFirst]);
    });

    test(
      'skips profile updates that are disabled, fresh, or file-based',
      () async {
        final profiles = [
          Profile.normal(label: 'Disabled').copyWith(autoUpdate: false),
          Profile.normal(label: 'Fresh').copyWith(
            autoUpdate: true,
            lastUpdateDate: DateTime.now().add(const Duration(days: 1)),
          ),
          Profile.normal(label: 'File').copyWith(
            autoUpdate: true,
            lastUpdateDate: DateTime.now().subtract(const Duration(days: 1)),
          ),
        ];
        final container = ProviderContainer(
          overrides: [
            currentProfileIdProvider.overrideWithBuild((_, _) => null),
            profilesProvider.overrideWith(() => TestProfiles(profiles)),
          ],
        );
        addTearDown(container.dispose);
        final action = container.read(profilesActionProvider.notifier);

        await action.autoUpdateProfiles();
        await action.updateProfiles();

        expect(container.read(profilesProvider), profiles);
      },
    );

    test('setProfileAndAutoApply stores a non-current profile', () {
      final current = Profile.normal(label: 'Current');
      final other = Profile.normal(label: 'Other');
      final container = ProviderContainer(
        overrides: [
          currentProfileIdProvider.overrideWithBuild((_, _) => current.id),
          profilesProvider.overrideWith(() => TestProfiles([current])),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(profilesActionProvider.notifier)
          .setProfileAndAutoApply(other);

      expect(container.read(profilesProvider), [current, other]);
      expect(container.read(currentProfileIdProvider), current.id);
    });
  });

  group('ScriptsAction', () {
    ProviderContainer scriptsContainer(
      Profile profile,
      _ApplyRecordingSetupAction setupAction,
    ) {
      final container = ProviderContainer(
        overrides: [
          currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
          profilesProvider.overrideWith(() => TestProfiles([profile])),
          scriptsProvider.overrideWith(_MemoryScripts.new),
          setupActionProvider.overrideWith(() => setupAction),
        ],
      );
      addTearDown(container.dispose);
      container.listen(scriptsProvider, (_, _) {});
      return container;
    }

    Script script(int id, {String? url}) => Script(
      id: id,
      label: 'Script $id',
      lastUpdateTime: DateTime(2026),
      url: url,
    );

    test('putScript re-applies only a current profile running that script', () {
      final profile = Profile.normal().copyWith(
        overwriteType: OverwriteType.script,
        scriptId: 1,
      );
      final setupAction = _ApplyRecordingSetupAction();
      final container = scriptsContainer(profile, setupAction);
      final action = container.read(scriptsActionProvider.notifier);

      action.putScript(script(2));
      expect(setupAction.applyCount, 0);

      action.putScript(script(1));
      expect(setupAction.applyCount, 1);
      expect(container.read(scriptsProvider).value?.map((item) => item.id), [
        2,
        1,
      ]);

      container
          .read(profilesProvider.notifier)
          .put(profile.copyWith(overwriteType: OverwriteType.standard));
      action.putScript(script(1));
      expect(setupAction.applyCount, 1);
    });

    test(
      'updateScript releases the updating key when the download fails',
      () async {
        final profile = Profile.normal().copyWith(
          overwriteType: OverwriteType.script,
          scriptId: 1,
        );
        final setupAction = _ApplyRecordingSetupAction();
        final container = scriptsContainer(profile, setupAction);
        final remote = script(1, url: 'bad-url');

        await expectLater(
          container.read(scriptsActionProvider.notifier).updateScript(remote),
          throwsA(anything),
        );

        expect(container.read(isUpdatingProvider(remote.updatingKey)), isFalse);
        expect(container.read(scriptsProvider).value, isEmpty);
        expect(setupAction.applyCount, 0);
      },
    );
  });

  group('GeoResourceAction', () {
    test('GeoResource has correct updatingKey', () {
      expect(GeoResource.MMDB.updatingKey, 'geo_resource_MMDB');
      expect(GeoResource.ASN.updatingKey, 'geo_resource_ASN');
      expect(GeoResource.GEOIP.updatingKey, 'geo_resource_GEOIP');
      expect(GeoResource.GEOSITE.updatingKey, 'geo_resource_GEOSITE');
    });

    test('IsUpdating provider works with geo resource key', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final key = GeoResource.MMDB.updatingKey;
      expect(container.read(isUpdatingProvider(key)), false);

      final operation = container
          .read(updatingKeysProvider.notifier)
          .start(key);
      expect(container.read(isUpdatingProvider(key)), true);

      container.read(updatingKeysProvider.notifier).stop(key, operation);
      expect(container.read(isUpdatingProvider(key)), false);
    });

    test('forwards a manual resource update to Core', () async {
      final core = _MockCoreHandlerInterface();
      when(() => core.updateGeoData('MMDB')).thenAnswer((_) async => '');
      final container = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        ],
      );
      addTearDown(container.dispose);
      final action = container.read(geoResourceActionProvider.notifier);

      await action.updateGeoResource(GeoResource.MMDB);

      verify(() => core.updateGeoData('MMDB')).called(1);
    });

    test('propagates a failed manual Core request', () async {
      final core = _MockCoreHandlerInterface();
      when(
        () => core.updateGeoData('MMDB'),
      ).thenThrow(StateError('disconnected'));
      final container = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        ],
      );
      addTearDown(container.dispose);
      final action = container.read(geoResourceActionProvider.notifier);

      await expectLater(
        action.updateGeoResource(GeoResource.MMDB),
        throwsStateError,
      );
      verify(() => core.updateGeoData('MMDB')).called(1);
    });

    test('updates valid resource URLs and rejects malformed URLs', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final action = container.read(geoResourceActionProvider.notifier);

      expect(
        () => action.updateGeoResourceUrl(GeoResource.MMDB, 'not-a-url'),
        throwsA(isA<ArgumentError>()),
      );

      const url = 'https://example.com/Country.mmdb';
      action.updateGeoResourceUrl(GeoResource.MMDB, url);
      expect(
        container.read(patchClashConfigProvider).geoXUrl[GeoResource.MMDB],
        url,
      );
    });
  });

  group('CoreAction', () {
    test('applies the profile after restarting a stopped core', () async {
      final container = ProviderContainer(
        overrides: [
          coreActionProvider.overrideWith(_TestCoreAction.new),
          setupActionProvider.overrideWith(_TestSetupAction.new),
        ],
      );
      addTearDown(container.dispose);
      final coreAction =
          container.read(coreActionProvider.notifier) as _TestCoreAction;
      final setupAction =
          container.read(setupActionProvider.notifier) as _TestSetupAction;

      await coreAction.restartCore();

      expect(coreAction.lifecycleRestartCount, 1);
      expect(setupAction.setRunningCount, 0);
      expect(setupAction.applyProfileCount, 1);
    });

    test(
      'restores the started state after restarting a running core',
      () async {
        final container = ProviderContainer(
          overrides: [
            coreActionProvider.overrideWith(_TestCoreAction.new),
            setupActionProvider.overrideWith(_TestSetupAction.new),
          ],
        );
        addTearDown(container.dispose);
        container.read(runTimeProvider.notifier).value = 0;
        final coreAction =
            container.read(coreActionProvider.notifier) as _TestCoreAction;
        final setupAction =
            container.read(setupActionProvider.notifier) as _TestSetupAction;

        await coreAction.restartCore();

        expect(coreAction.lifecycleRestartCount, 1);
        expect(setupAction.setRunningCount, 1);
        expect(setupAction.applyProfileCount, 0);
      },
    );

    test(
      'a rejected setup while running reports restartCore as unsuccessful',
      () async {
        final container = ProviderContainer(
          overrides: [
            coreActionProvider.overrideWith(_TestCoreAction.new),
            setupActionProvider.overrideWith(_TestSetupAction.new),
          ],
        );
        addTearDown(container.dispose);
        container.read(runTimeProvider.notifier).value = 0;
        final coreAction =
            container.read(coreActionProvider.notifier) as _TestCoreAction;
        final setupAction =
            container.read(setupActionProvider.notifier) as _TestSetupAction;
        setupAction.setRunningResult = false;

        final applied = await coreAction.restartCore();

        expect(applied, isFalse);
        expect(setupAction.setRunningCount, 1);
      },
    );

    test(
      'coalesces concurrent restart requests into one lifecycle restart',
      () async {
        final container = ProviderContainer(
          overrides: [
            coreActionProvider.overrideWith(_TestCoreAction.new),
            setupActionProvider.overrideWith(_TestSetupAction.new),
          ],
        );
        addTearDown(container.dispose);
        final coreAction =
            container.read(coreActionProvider.notifier) as _TestCoreAction;
        final setupAction =
            container.read(setupActionProvider.notifier) as _TestSetupAction;
        final restartCompleter = Completer<CoreLifecycleResult>();
        coreAction.restartCompleter = restartCompleter;

        final first = coreAction.restartCore();
        final second = coreAction.restartCore();
        await Future<void>.delayed(Duration.zero);

        expect(coreAction.lifecycleRestartCount, 1);
        restartCompleter.complete(_restartResult);
        await Future.wait([first, second]);

        expect(setupAction.applyProfileCount, 1);
      },
    );

    test('reapplies the latest request without restarting twice', () async {
      final container = ProviderContainer(
        overrides: [
          coreActionProvider.overrideWith(_TestCoreAction.new),
          setupActionProvider.overrideWith(_TestSetupAction.new),
        ],
      );
      addTearDown(container.dispose);
      final coreAction =
          container.read(coreActionProvider.notifier) as _TestCoreAction;
      final setupAction =
          container.read(setupActionProvider.notifier) as _TestSetupAction;
      final restartCompleter = Completer<CoreLifecycleResult>();
      final firstApplyStarted = Completer<void>();
      final firstApplyCompleter = Completer<void>();
      coreAction.restartCompleter = restartCompleter;
      setupAction.firstApplyStarted = firstApplyStarted;
      setupAction.firstApplyCompleter = firstApplyCompleter;

      final first = coreAction.restartCore();
      await Future<void>.delayed(Duration.zero);
      restartCompleter.complete(_restartResult);
      await firstApplyStarted.future;

      final second = coreAction.restartCore();
      firstApplyCompleter.complete();
      await Future.wait([first, second]);

      expect(coreAction.lifecycleRestartCount, 1);
      expect(setupAction.applyProfileCount, 2);
    });

    test('surfaces a failed restart to its caller as a rejection', () async {
      final container = ProviderContainer(
        overrides: [
          coreActionProvider.overrideWith(_TestCoreAction.new),
          setupActionProvider.overrideWith(_TestSetupAction.new),
        ],
      );
      addTearDown(container.dispose);
      final coreAction =
          container.read(coreActionProvider.notifier) as _TestCoreAction;
      final restartCompleter = Completer<CoreLifecycleResult>();
      coreAction.restartCompleter = restartCompleter;

      final restart = coreAction.restartCore();
      restartCompleter.completeError(StateError('core is gone'));

      await expectLater(restart, throwsA(isA<StateError>()));
      expect(container.read(coreStatusProvider), CoreStatus.disconnected);

      // The failed operation must not latch: a later restart still runs.
      coreAction.restartCompleter = null;
      await coreAction.restartCore();
      expect(coreAction.lifecycleRestartCount, 2);
      expect(container.read(coreStatusProvider), CoreStatus.connected);
    });

    test(
      'startCore leaves status and initCore to the superseding operation',
      () async {
        final container = ProviderContainer(
          overrides: [coreActionProvider.overrideWith(_TestCoreAction.new)],
        );
        addTearDown(container.dispose);
        final coreAction =
            container.read(coreActionProvider.notifier) as _TestCoreAction;
        coreAction.startResult = const CoreLifecycleResult(
          revision: 1,
          outcome: CoreLifecycleOutcome.superseded,
        );

        await coreAction.startCore();

        expect(coreAction.initCoreCount, 0);
        expect(container.read(coreStatusProvider), CoreStatus.connecting);
      },
    );

    test('startCore treats a coalesced outcome as applied', () async {
      final container = ProviderContainer(
        overrides: [coreActionProvider.overrideWith(_TestCoreAction.new)],
      );
      addTearDown(container.dispose);
      final coreAction =
          container.read(coreActionProvider.notifier) as _TestCoreAction;
      coreAction.startResult = const CoreLifecycleResult(
        revision: 1,
        outcome: CoreLifecycleOutcome.coalesced,
      );

      await coreAction.startCore();

      expect(coreAction.initCoreCount, 1);
      expect(container.read(coreStatusProvider), CoreStatus.connected);
    });

    test(
      'restartCore leaves status and initCore to the superseding operation',
      () async {
        final container = ProviderContainer(
          overrides: [
            coreActionProvider.overrideWith(_TestCoreAction.new),
            setupActionProvider.overrideWith(_TestSetupAction.new),
          ],
        );
        addTearDown(container.dispose);
        final coreAction =
            container.read(coreActionProvider.notifier) as _TestCoreAction;
        final setupAction =
            container.read(setupActionProvider.notifier) as _TestSetupAction;
        coreAction.restartCompleter = Completer<CoreLifecycleResult>()
          ..complete(
            const CoreLifecycleResult(
              revision: 1,
              outcome: CoreLifecycleOutcome.superseded,
            ),
          );

        final applied = await coreAction.restartCore();

        expect(applied, isFalse);
        expect(coreAction.initCoreCount, 0);
        expect(container.read(coreStatusProvider), CoreStatus.connecting);
        expect(setupAction.setRunningCount, 0);
        expect(setupAction.applyProfileCount, 0);
      },
    );

    test('restartCore treats a coalesced outcome as applied', () async {
      final container = ProviderContainer(
        overrides: [
          coreActionProvider.overrideWith(_TestCoreAction.new),
          setupActionProvider.overrideWith(_TestSetupAction.new),
        ],
      );
      addTearDown(container.dispose);
      final coreAction =
          container.read(coreActionProvider.notifier) as _TestCoreAction;
      coreAction.restartCompleter = Completer<CoreLifecycleResult>()
        ..complete(
          const CoreLifecycleResult(
            revision: 1,
            outcome: CoreLifecycleOutcome.coalesced,
          ),
        );

      await coreAction.restartCore();

      expect(coreAction.initCoreCount, 1);
      expect(container.read(coreStatusProvider), CoreStatus.connected);
    });
  });

  group('SetupAction', () {
    test('a full setup clears stale delay state', () async {
      final action = _TestSetupAction();
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          setupActionProvider.overrideWith(() => action),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(delayDataSourceProvider.notifier)
          .setDelay(
            const Delay(
              name: 'HK-01',
              url: 'https://example.test/204',
              value: 42,
            ),
          );

      expect(
        await container.read(setupActionProvider.notifier).fullSetup(),
        isTrue,
      );

      expect(container.read(delayDataSourceProvider), isEmpty);
    });

    group('rapid status changes', () {
      test('updates runtime and traffic while core start is pending', () async {
        final startCompleter = Completer<bool>();
        final container = ProviderContainer(
          overrides: [
            initProvider.overrideWithBuild((_, _) => true),
            commonActionProvider.overrideWith(_RaceCommonAction.new),
            setupActionProvider.overrideWith(_RaceSetupAction.new),
          ],
        );
        addTearDown(container.dispose);
        final action =
            container.read(setupActionProvider.notifier) as _RaceSetupAction;
        final commonAction =
            container.read(commonActionProvider.notifier) as _RaceCommonAction;
        action.startCompleter = startCompleter;

        final startFuture = action.setRunning(true);
        final initialRunTime = container.read(runTimeProvider)!;
        // Visible ticker is 1.5s; wait past one period for the second traffic read.
        await Future<void>.delayed(const Duration(milliseconds: 1600));

        expect(container.read(runTimeProvider), greaterThan(initialRunTime));
        expect(commonAction.updateTrafficCount, greaterThanOrEqualTo(2));

        startCompleter.complete(true);
        await startFuture;

        expect(action.transitions, [true]);
        await action.setRunning(false);
      });

      test('serializes listener changes while latest start owns UI', () async {
        final stopCompleter = Completer<bool>();
        final container = ProviderContainer(
          overrides: [
            initProvider.overrideWithBuild((_, _) => true),
            commonActionProvider.overrideWith(_RaceCommonAction.new),
            setupActionProvider.overrideWith(_RaceSetupAction.new),
          ],
        );
        addTearDown(container.dispose);
        final action =
            container.read(setupActionProvider.notifier) as _RaceSetupAction;
        await action.setRunning(true);
        action.transitions.clear();
        action.applyProfileDebounceCount = 0;
        action.stopCompleter = stopCompleter;

        final stopFuture = action.setRunning(false);
        await Future<void>.delayed(Duration.zero);
        expect(action.transitions, [false]);

        final startFuture = action.setRunning(true);

        expect(container.read(runTimeProvider), isNotNull);

        stopCompleter.complete(true);
        await Future.wait([stopFuture, startFuture]);

        expect(action.transitions, [false, true]);
        expect(container.read(runTimeProvider), isNotNull);
        expect(container.read(isStartProvider), isTrue);
        expect(action.applyProfileDebounceCount, 1);
        expect(action.resetCoreTrafficCount, 0);

        await action.setRunning(false);
      });

      test('newer stop prevents stale start continuation', () async {
        final startCompleter = Completer<bool>();
        final container = ProviderContainer(
          overrides: [
            initProvider.overrideWithBuild((_, _) => true),
            commonActionProvider.overrideWith(_RaceCommonAction.new),
            setupActionProvider.overrideWith(_RaceSetupAction.new),
          ],
        );
        addTearDown(container.dispose);
        final action =
            container.read(setupActionProvider.notifier) as _RaceSetupAction;
        action.startCompleter = startCompleter;

        final startFuture = action.setRunning(true);
        await Future<void>.delayed(Duration.zero);
        expect(action.transitions, [true]);

        final stopFuture = action.setRunning(false);
        expect(container.read(runTimeProvider), isNull);

        startCompleter.complete(true);
        await Future.wait([startFuture, stopFuture]);

        expect(action.transitions, [true, false]);
        expect(container.read(runTimeProvider), isNull);
        expect(container.read(isStartProvider), isFalse);
        expect(action.applyProfileDebounceCount, 0);
        expect(action.resetCoreTrafficCount, 1);
      });

      test('skips an intermediate stop when a newer start is queued', () async {
        final startCompleter = Completer<bool>();
        final container = ProviderContainer(
          overrides: [
            initProvider.overrideWithBuild((_, _) => true),
            commonActionProvider.overrideWith(_RaceCommonAction.new),
            setupActionProvider.overrideWith(_RaceSetupAction.new),
          ],
        );
        addTearDown(container.dispose);
        final action =
            container.read(setupActionProvider.notifier) as _RaceSetupAction;
        action.startCompleter = startCompleter;

        final firstStart = action.setRunning(true);
        await Future<void>.delayed(Duration.zero);
        final stop = action.setRunning(false);
        final latestStart = action.setRunning(true);

        startCompleter.complete(true);
        await Future.wait([firstStart, stop, latestStart]);

        expect(action.transitions, [true, true]);
        expect(container.read(isStartProvider), isTrue);
        expect(action.applyProfileDebounceCount, 1);
        expect(action.resetCoreTrafficCount, 0);

        await action.setRunning(false);
      });

      test('stale initialization cannot start after a newer stop', () async {
        final container = ProviderContainer(
          overrides: [
            initProvider.overrideWithBuild((_, _) => true),
            commonActionProvider.overrideWith(_RaceCommonAction.new),
            setupActionProvider.overrideWith(_InitializingSetupAction.new),
          ],
        );
        addTearDown(container.dispose);
        final action =
            container.read(setupActionProvider.notifier)
                as _InitializingSetupAction;

        final start = action.setRunning(true, initialize: true);
        final stop = action.setRunning(false);
        await stop;

        expect(action.transitions, [false]);
        expect(container.read(isStartProvider), isFalse);

        action.continueInitialization();
        await start;

        expect(action.transitions, [false]);
        expect(container.read(isStartProvider), isFalse);
      });

      test(
        'keeps suspended startup local until the listener resumes',
        () async {
          final container = ProviderContainer(
            overrides: [
              initProvider.overrideWithBuild((_, _) => true),
              suspendProvider.overrideWithValue(true),
              commonActionProvider.overrideWith(_RaceCommonAction.new),
              setupActionProvider.overrideWith(_RaceSetupAction.new),
            ],
          );
          addTearDown(container.dispose);
          final action =
              container.read(setupActionProvider.notifier) as _RaceSetupAction;

          await action.setRunning(true);

          expect(action.transitions, isEmpty);
          expect(container.read(isStartProvider), isTrue);
          expect(action.applyProfileDebounceCount, 1);

          await action.setRunning(false);
          expect(action.transitions, [false]);
        },
      );
    });

    test(
      'restarts core after newly granting admin during config update',
      () async {
        late _AuthorizationSetupAction setupAction;
        late _RestartRecordingCoreAction coreAction;
        final container = ProviderContainer(
          overrides: [
            setupActionProvider.overrideWith(() {
              setupAction = _AuthorizationSetupAction([AuthorizeCode.success]);
              return setupAction;
            }),
            coreActionProvider.overrideWith(() {
              coreAction = _RestartRecordingCoreAction();
              return coreAction;
            }),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(patchClashConfigProvider.notifier)
            .update((state) => state.copyWith.tun(enable: true));
        container.read(setupActionProvider);
        container.read(coreActionProvider);

        await setupAction.updateConfig();

        expect(setupAction.authorizationRequestCount, 1);
        expect(
          container.read(authorizedTunEnableProvider),
          TunAuthorizationState.authorized,
        );
        expect(coreAction.restartCount, 1);
      },
    );

    test(
      'a config Core rejects on the handoff path reports failure, not success',
      () async {
        late _AuthorizationSetupAction setupAction;
        late _RestartRecordingCoreAction coreAction;
        final container = ProviderContainer(
          overrides: [
            currentProfileProvider.overrideWithValue(null),
            setupActionProvider.overrideWith(() {
              setupAction = _AuthorizationSetupAction([AuthorizeCode.success]);
              return setupAction;
            }),
            coreActionProvider.overrideWith(() {
              coreAction = _RestartRecordingCoreAction()..restartResult = false;
              return coreAction;
            }),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(patchClashConfigProvider.notifier)
            .update((state) => state.copyWith.tun(enable: true));
        container.read(setupActionProvider);
        container.read(coreActionProvider);

        final succeeded = await setupAction.applyProfile(force: true);

        expect(coreAction.restartCount, 1);
        expect(succeeded, isFalse);
      },
    );

    test('reopens authorization and propagates a failed restart', () async {
      late _AuthorizationSetupAction setupAction;
      final container = ProviderContainer(
        overrides: [
          currentProfileProvider.overrideWithValue(null),
          setupActionProvider.overrideWith(() {
            setupAction = _AuthorizationSetupAction([AuthorizeCode.success]);
            return setupAction;
          }),
          coreActionProvider.overrideWith(_FailingRestartCoreAction.new),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(patchClashConfigProvider.notifier)
          .update((state) => state.copyWith.tun(enable: true));
      container.read(setupActionProvider);
      container.read(coreActionProvider);

      await expectLater(
        setupAction.applyProfile(force: true),
        throwsA(same(_restartFailure)),
      );

      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.none,
      );
    });

    test('requests admin authorization once per app lifecycle', () async {
      late _AuthorizationSetupAction setupAction;
      final container = ProviderContainer(
        overrides: [
          setupActionProvider.overrideWith(() {
            setupAction = _AuthorizationSetupAction([
              AuthorizeCode.error,
              AuthorizeCode.success,
            ]);
            return setupAction;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(setupActionProvider);

      expect(await setupAction.requestAdmin(true), isTrue);
      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.unauthorized,
      );

      expect(await setupAction.requestAdmin(true), isTrue);
      expect(setupAction.authorizationRequestCount, 1);
      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.unauthorized,
      );
    });

    test('keeps tun disabled while authorization stays unauthorized', () async {
      late _AuthorizationSetupAction setupAction;
      final container = ProviderContainer(
        overrides: [
          setupActionProvider.overrideWith(() {
            setupAction = _AuthorizationSetupAction([AuthorizeCode.error]);
            return setupAction;
          }),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(patchClashConfigProvider.notifier)
          .update((state) => state.copyWith.tun(enable: true));
      container.read(setupActionProvider);

      await setupAction.requestAdmin(true);

      expect(container.read(shouldPatchSystemDnsProvider), isFalse);
    });

    test('a lost core ends the session without calling the core', () async {
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          commonActionProvider.overrideWith(_RaceCommonAction.new),
          setupActionProvider.overrideWith(_RaceSetupAction.new),
        ],
      );
      addTearDown(container.dispose);
      final trafficSubscription = container.listen(trafficsProvider, (_, _) {});
      final totalSubscription = container.listen(
        totalTrafficProvider,
        (_, _) {},
      );
      addTearDown(trafficSubscription.close);
      addTearDown(totalSubscription.close);
      final action =
          container.read(setupActionProvider.notifier) as _RaceSetupAction;
      await action.setRunning(true);
      container
          .read(trafficsProvider.notifier)
          .addTraffic(const Traffic(up: 1, down: 2));
      container.read(totalTrafficProvider.notifier).value = const Traffic(
        up: 3,
        down: 4,
      );
      expect(container.read(isStartProvider), isTrue);

      action.markCoreLost();

      expect(container.read(isStartProvider), isFalse);
      expect(container.read(runTimeProvider), isNull);
      expect(container.read(trafficsProvider).list, isEmpty);
      expect(container.read(totalTrafficProvider), const Traffic());
      expect(action.resetCoreTrafficCount, 0);
    });

    test('starting a core that is gone brings the process back', () async {
      final coreAction = _RestartRecordingCoreAction();
      late _RaceSetupAction action;
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          coreActionProvider.overrideWith(() => coreAction),
          commonActionProvider.overrideWith(_RaceCommonAction.new),
          setupActionProvider.overrideWith(() {
            action = _RaceSetupAction();
            return action;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(setupActionProvider);
      action.startError = const CoreMethodException(
        code: 'transport_disconnected',
        message: 'the core is gone',
      );

      expect(await action.setRunning(true), isTrue);

      expect(coreAction.restartCount, 1);
      // The press asks for the proxy: the listener is retried once the Core is
      // back, so the session ends up running rather than merely revived.
      expect(action.transitions, [true, true]);
      expect(container.read(isStartProvider), isTrue);
    });

    test('a core that keeps dying is restarted once, then reported', () async {
      final coreAction = _RestartRecordingCoreAction();
      late _RaceSetupAction action;
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          coreActionProvider.overrideWith(() => coreAction),
          commonActionProvider.overrideWith(_RaceCommonAction.new),
          setupActionProvider.overrideWith(() {
            action = _RaceSetupAction();
            return action;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(setupActionProvider);
      action.startError = const CoreMethodException(
        code: 'transport_disconnected',
        message: 'the core is gone',
      );
      action.startErrorPersists = true;

      await expectLater(
        action.setRunning(true),
        throwsA(isA<CoreMethodException>()),
      );

      expect(coreAction.restartCount, 1);
    });

    test('starting a connected core still toggles the listener', () async {
      final coreAction = _RestartRecordingCoreAction();
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          coreActionProvider.overrideWith(() => coreAction),
          commonActionProvider.overrideWith(_RaceCommonAction.new),
          setupActionProvider.overrideWith(_RaceSetupAction.new),
        ],
      );
      addTearDown(container.dispose);
      final action =
          container.read(setupActionProvider.notifier) as _RaceSetupAction;
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;

      expect(await action.setRunning(true), isTrue);

      expect(coreAction.restartCount, 0);
      expect(action.transitions, [true]);
    });
  });
}

class _TestCoreAction extends CoreAction {
  int lifecycleRestartCount = 0;
  int initCoreCount = 0;
  Completer<CoreLifecycleResult>? restartCompleter;
  Completer<CoreLifecycleResult>? startCompleter;
  CoreLifecycleResult startResult = _restartResult;

  @override
  Future<void> initCore() async {
    initCoreCount++;
  }

  @override
  Future<CoreLifecycleResult> startLifecycle() {
    return startCompleter?.future ?? Future.value(startResult);
  }

  @override
  Future<CoreLifecycleResult> restartLifecycle() {
    lifecycleRestartCount++;
    return restartCompleter?.future ?? Future.value(_restartResult);
  }
}

class _ApplyRecordingSetupAction extends SetupAction {
  int applyCount = 0;

  @override
  void applyProfileDebounce({bool silence = false, bool force = false}) {
    applyCount++;
  }
}

class _MemoryScripts extends Scripts {
  @override
  Stream<List<Script>> build() => Stream.value(const []);

  @override
  void put(Script script) {
    state = AsyncData([...value.where((item) => item.id != script.id), script]);
  }
}

class _TestSetupAction extends SetupAction {
  int setRunningCount = 0;
  int applyProfileCount = 0;
  bool setRunningResult = true;
  Completer<void>? firstApplyStarted;
  Completer<void>? firstApplyCompleter;

  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    setRunningCount++;
    return setRunningResult;
  }

  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    applyProfileCount++;
    if (applyProfileCount == 1) {
      firstApplyStarted?.complete();
      await firstApplyCompleter?.future;
    }
    return true;
  }
}

const _restartResult = CoreLifecycleResult(
  revision: 1,
  outcome: CoreLifecycleOutcome.applied,
);

class _RestartRecordingCoreAction extends CoreAction {
  int restartCount = 0;
  bool restartResult = true;

  @override
  Future<bool> restartCore() async {
    restartCount++;
    return restartResult;
  }
}

class _FailingRestartCoreAction extends CoreAction {
  @override
  Future<bool> restartCore() async {
    throw _restartFailure;
  }
}

final _restartFailure = Exception('restart failed');

class _AuthorizationSetupAction extends SetupAction {
  final List<AuthorizeCode> authorizationResults;
  int authorizationRequestCount = 0;

  _AuthorizationSetupAction(this.authorizationResults);

  @override
  Future<AuthorizeCode> authorizeCore() async {
    return authorizationResults[authorizationRequestCount++];
  }
}

class _RaceSetupAction extends SetupAction {
  int applyProfileDebounceCount = 0;
  int resetCoreTrafficCount = 0;
  final transitions = <bool>[];
  Completer<bool>? startCompleter;
  Completer<bool>? stopCompleter;
  Exception? startError;
  bool startErrorPersists = false;

  @override
  void applyProfileDebounce({bool silence = false, bool force = false}) {
    applyProfileDebounceCount++;
  }

  @override
  Future<bool> setCoreRunning(bool running) async {
    transitions.add(running);
    final startError = this.startError;
    if (running && startError != null) {
      if (!startErrorPersists) {
        this.startError = null;
      }
      throw startError;
    }
    return running
        ? await startCompleter?.future ?? true
        : await stopCompleter?.future ?? true;
  }

  @override
  void resetCoreTraffic() {
    resetCoreTrafficCount++;
  }
}

class _InitializingSetupAction extends _RaceSetupAction {
  final _initializationCompleter = Completer<void>();

  void continueInitialization() {
    _initializationCompleter.complete();
  }

  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    await _initializationCompleter.future;
    await preloadInvoke?.call();
    return true;
  }
}

class _RaceCommonAction extends CommonAction {
  int updateTrafficCount = 0;

  @override
  Future<void> updateTraffic() async {
    updateTrafficCount++;
  }
}
