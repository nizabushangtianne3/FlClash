part of '../action.dart';

bool profileUpdateStateChanged(Profile previous, Profile next) {
  return previous.url != next.url ||
      previous.autoUpdate != next.autoUpdate ||
      previous.autoUpdateDuration != next.autoUpdateDuration ||
      previous.lastUpdateDate != next.lastUpdateDate;
}

@visibleForTesting
bool sameProfileUpdateState(List<Profile> previous, List<Profile> next) {
  if (previous.length != next.length) {
    return false;
  }
  final previousById = {for (final profile in previous) profile.id: profile};
  for (final profile in next) {
    final old = previousById[profile.id];
    if (old == null || profileUpdateStateChanged(old, profile)) {
      return false;
    }
  }
  return true;
}

@visibleForTesting
Profile mergeRequestedProfile({
  required Profile requested,
  required Profile current,
}) {
  return current.copyWith(
    label: requested.label,
    url: requested.url,
    autoUpdate: requested.autoUpdate,
    autoUpdateDuration: requested.autoUpdateDuration,
  );
}

@visibleForTesting
bool shouldApplyUpdatedProfile({
  required Profile downloaded,
  required Profile latest,
  required int? currentProfileId,
}) {
  return downloaded.id == currentProfileId && downloaded.url == latest.url;
}

@visibleForTesting
Profile mergeUpdatedProfile({
  required Profile original,
  required Profile current,
  required Profile updated,
}) {
  return current.copyWith(
    label: current.label == original.label ? updated.label : current.label,
    subscriptionInfo: updated.subscriptionInfo,
    lastUpdateDate: updated.lastUpdateDate,
  );
}

class _PendingProfileUpdate {
  _PendingProfileUpdate({
    required this.profile,
    required this.showLoading,
    required this.renameIn,
  });

  final Completer<void> waiter = Completer<void>();
  Profile profile;
  bool showLoading;
  Iterable<int> renameIn;
}

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  Future<Set<int>>? _autoUpdateOperation;
  Future<List<UpdatingMessage>>? _updateProfilesOperation;
  List<Profile>? _updateProfilesSnapshot;
  final _activeProfileUpdates = <int, Future<void>>{};
  final _pendingProfileUpdates = <int, _PendingProfileUpdate>{};

  @override
  void build() {}

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      ref
          .read(profilesProvider.notifier)
          .put(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  Future<void> deleteProfile(int id) async {
    await ref.read(profilesProvider.notifier).del(id);
    await clearEffect(id);
    final currentProfileId = ref.read(currentProfileIdProvider);
    if (currentProfileId == id) {
      final profiles = ref.read(profilesProvider);
      if (profiles.isNotEmpty) {
        final updateId = profiles.first.id;
        ref.read(currentProfileIdProvider.notifier).value = updateId;
      } else {
        ref.read(currentProfileIdProvider.notifier).value = null;
        unawaited(ref.read(setupActionProvider.notifier).setRunning(false));
      }
    }
  }

  Future<String> validateConfigWithData(String data) async {
    return _core.validateConfigWithData(data);
  }

  /// Startup and the periodic task can both fire before the first run ends;
  /// sharing one future keeps a slow subscription from being fetched twice.
  Future<Set<int>> autoUpdateProfiles({Set<int> skipProfileIds = const {}}) {
    final running = _autoUpdateOperation;
    if (running != null) {
      return running;
    }
    return _autoUpdateOperation = _runAutoUpdateProfiles(skipProfileIds)
        .whenComplete(() {
          _autoUpdateOperation = null;
        });
  }

  Future<Set<int>> _runAutoUpdateProfiles(Set<int> skipProfileIds) async {
    final failed = <int>{};
    final now = DateTime.now();
    for (final profile in ref.read(profilesProvider)) {
      if (!profile.realAutoUpdate || !profile.isAutoUpdateDue(now)) {
        continue;
      }
      if (skipProfileIds.contains(profile.id)) {
        continue;
      }
      try {
        await updateProfile(profile);
      } catch (e) {
        failed.add(profile.id);
        commonPrint.log(compactError(e), logLevel: LogLevel.warning);
      }
    }
    return failed;
  }

  void putProfile(Profile profile, {Iterable<int> renameIn = const []}) {
    ref.read(profilesProvider.notifier).put(profile, renameIn: renameIn);
    if (ref.read(currentProfileIdProvider) != null) return;
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<List<Profile>> providerUsers(Profile profile) async {
    if (!feature.customProviders) {
      return const [];
    }
    final users = await ref
        .read(clashProvidersActionProvider.notifier)
        .profilesReferencing(ProviderKind.proxy, profile.realLabel);
    return [
      for (final user in users)
        if (user.id != profile.id) user,
    ];
  }

  /// [conflicts] would move to their subscription's provider of the new name.
  Future<({List<Profile> renameIn, List<Profile> conflicts})> providerRename(
    Profile previous,
    Profile next,
  ) async {
    final label = ref.read(profilesProvider.notifier).labeled(next).realLabel;
    if (!feature.customProviders || label == previous.realLabel) {
      return (renameIn: const <Profile>[], conflicts: const <Profile>[]);
    }
    final renameIn = await providerUsers(previous);
    final conflicts = await ref
        .read(clashProvidersActionProvider.notifier)
        .profilesDefining(ProviderKind.proxy, label, renameIn);
    return (renameIn: renameIn, conflicts: conflicts);
  }

  /// Sweeps every subscription and hands back what failed, instead of stopping
  /// at the first failure: one dead link used to leave every profile after it
  /// stale, however often the sweep was run.
  Future<List<UpdatingMessage>> updateProfiles() {
    final running = _updateProfilesOperation;
    if (running != null) {
      return running;
    }
    _updateProfilesSnapshot = ref.read(profilesProvider);
    return _updateProfilesOperation = _drainUpdateProfiles().whenComplete(() {
      _updateProfilesOperation = null;
      _updateProfilesSnapshot = null;
    });
  }

  Future<List<UpdatingMessage>> _drainUpdateProfiles() async {
    final messages = <UpdatingMessage>[];
    while (true) {
      messages.addAll(await _runUpdateProfiles());
      if (!ref.mounted) {
        break;
      }
      final profiles = ref.read(profilesProvider);
      final snapshot = _updateProfilesSnapshot;
      if (snapshot == null || sameProfileUpdateState(snapshot, profiles)) {
        break;
      }
      _updateProfilesSnapshot = profiles;
    }
    return messages;
  }

  Future<List<UpdatingMessage>> _runUpdateProfiles() async {
    final messages = <UpdatingMessage>[];
    await Future.wait([
      for (final profile in ref.read(profilesProvider))
        if (profile.type != ProfileType.file)
          () async {
            try {
              await updateProfile(profile, showLoading: true);
            } catch (error) {
              messages.add(
                UpdatingMessage(
                  label: profile.realLabel,
                  message: userFacingErrorMessage(
                    error,
                    currentAppLocalizations,
                  ),
                ),
              );
            }
          }(),
    ]);
    return messages;
  }

  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
    Iterable<int> renameIn = const [],
  }) {
    return _updateProfile(
      profile,
      showLoading: showLoading,
      renameIn: renameIn,
      applyProfileState: true,
    );
  }

  Future<void> _updateProfile(
    Profile profile, {
    required bool showLoading,
    required Iterable<int> renameIn,
    required bool applyProfileState,
  }) {
    final active = _activeProfileUpdates[profile.id];
    if (active != null) {
      final currentProfile = ref.read(profilesProvider).getProfile(profile.id);
      if (currentProfile == null) {
        final pending = _pendingProfileUpdates.remove(profile.id);
        pending?.waiter.complete();
        return Future.value();
      }
      final requestedProfile = mergeRequestedProfile(
        requested: profile,
        current: currentProfile,
      );
      ref
          .read(profilesProvider.notifier)
          .put(requestedProfile, renameIn: renameIn);
      _recordSweptProfile(requestedProfile);
      final pending = _pendingProfileUpdates.putIfAbsent(
        profile.id,
        () => _PendingProfileUpdate(
          profile: requestedProfile,
          showLoading: showLoading,
          renameIn: renameIn,
        ),
      );
      pending
        ..profile = requestedProfile
        ..showLoading = showLoading
        ..renameIn = renameIn;
      return pending.waiter.future;
    }

    final task = updateProfileNow(
      profile,
      showLoading: showLoading,
      renameIn: renameIn,
      applyProfileState: applyProfileState,
    );
    _activeProfileUpdates[profile.id] = task;
    return task.whenComplete(() {
      if (!identical(_activeProfileUpdates[profile.id], task)) {
        return;
      }
      _activeProfileUpdates.remove(profile.id);
      final pending = _pendingProfileUpdates.remove(profile.id);
      if (pending == null) {
        return;
      }
      _updateProfile(
        pending.profile,
        showLoading: pending.showLoading,
        renameIn: pending.renameIn,
        applyProfileState: false,
      ).then(
        pending.waiter.complete,
        onError: (Object error, StackTrace stackTrace) =>
            pending.waiter.completeError(error, stackTrace),
      );
    });
  }

  @visibleForTesting
  Future<void> updateProfileNow(
    Profile profile, {
    bool showLoading = false,
    Iterable<int> renameIn = const [],
    bool applyProfileState = true,
  }) async {
    final currentProfile = ref.read(profilesProvider).getProfile(profile.id);
    if (currentProfile == null) {
      return;
    }
    final profileToUpdate = applyProfileState
        ? mergeRequestedProfile(requested: profile, current: currentProfile)
        : profile;
    final operation = showLoading
        ? ref.read(updatingKeysProvider.notifier).start(profile.updatingKey)
        : null;
    try {
      if (applyProfileState) {
        ref
            .read(profilesProvider.notifier)
            .put(profileToUpdate, renameIn: renameIn);
        _recordSweptProfile(profileToUpdate);
      }
      final newProfile = await profileToUpdate.update(
        validate: (path) => _core.validateConfig(path),
      );
      final latestProfile = ref.read(profilesProvider).getProfile(profile.id);
      if (latestProfile == null) {
        final profilePath = await appPath.getProfilePath(profile.id.toString());
        await File(profilePath).safeDelete(recursive: true);
        return;
      }
      final savedProfile = mergeUpdatedProfile(
        original: profileToUpdate,
        current: latestProfile,
        updated: newProfile,
      );
      ref.read(profilesProvider.notifier).put(savedProfile);
      _recordSweptProfile(savedProfile);
      if (shouldApplyUpdatedProfile(
        downloaded: profileToUpdate,
        latest: latestProfile,
        currentProfileId: ref.read(currentProfileIdProvider),
      )) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      }
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(profile.updatingKey, operation);
      }
    }
  }

  void _recordSweptProfile(Profile profile) {
    final snapshot = _updateProfilesSnapshot;
    if (snapshot == null) {
      return;
    }
    final next = List<Profile>.of(snapshot);
    final index = next.indexWhere((item) => item.id == profile.id);
    if (index == -1) {
      next.add(profile);
    } else {
      next[index] = profile;
    }
    _updateProfilesSnapshot = next;
  }

  Future<void> addProfileFormFile() async {
    final platformFile = await globalState.safeRun(picker.pickerFile);
    if (platformFile == null) return;
    final bytes = await platformFile.readBytes();
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    ref.read(currentPageLabelProvider.notifier).toProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return Profile.normal(
          label: platformFile.name,
        ).saveFile(bytes, validate: (path) => _core.validateConfig(path));
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  Future<void> addProfileFormURL(String url, {String? label}) async {
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    ref.read(currentPageLabelProvider.notifier).value = PageLabel.profiles;
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return Profile.normal(
          label: label,
          url: url,
        ).update(validate: (path) => _core.validateConfig(path));
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  void setProfileAndAutoApply(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (profile.id == ref.read(currentProfileIdProvider)) {
      ref.read(setupActionProvider.notifier).applyProfileDebounce();
    }
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    unawaited(addProfileFormURL(url));
  }

  void reorder(List<Profile> profiles) {
    ref.read(profilesProvider.notifier).reorder(profiles);
  }

  Future<void> clearEffect(int profileId) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final profileFile = File(profilePath);
    final isExists = await profileFile.exists();
    if (isExists) {
      await profileFile.safeDelete(recursive: true);
    }
    try {
      final error = await _core.clearEffect(profileId);
      if (error.isNotEmpty) {
        commonPrint.log(error, logLevel: LogLevel.warning);
      }
    } catch (error) {
      commonPrint.log(
        'clearEffect($profileId) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }
}
