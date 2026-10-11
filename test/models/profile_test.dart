import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  group('SubscriptionInfo', () {
    test('parses subscription-userinfo header values', () {
      final info = SubscriptionInfo.formHString(
        'upload=10; download=20; total=100; expire=200',
      );

      expect(info.upload, 10);
      expect(info.download, 20);
      expect(info.total, 100);
      expect(info.expire, 200);
    });

    test('falls back to zero for null and invalid values', () {
      expect(SubscriptionInfo.formHString(null), const SubscriptionInfo());

      final info = SubscriptionInfo.formHString(
        'upload=bad; download=20; total=; expire=abc',
      );

      expect(info.upload, 0);
      expect(info.download, 20);
      expect(info.total, 0);
      expect(info.expire, 0);
    });

    test('survives the stray separators a panel may send', () {
      final info = SubscriptionInfo.formHString(
        'upload=10; ; =20; download=30; total=100; expire=200;',
      );

      expect(info.upload, 10);
      expect(info.download, 30);
      expect(info.total, 100);
      expect(info.expire, 200);
    });

    test('reads the expiry only when a date can hold it', () {
      expect(
        SubscriptionInfo.formHString('expire=1704067200').expireDate,
        DateTime.fromMillisecondsSinceEpoch(1704067200000),
      );
      expect(SubscriptionInfo.formHString('expire=0').expireDate, isNull);
      expect(SubscriptionInfo.formHString('expire=-1').expireDate, isNull);
      expect(
        SubscriptionInfo.formHString('expire=999999999999999').expireDate,
        isNull,
      );
    });
  });

  group('ProfileExtension', () {
    test('derives type, label, filename, and updating key', () {
      const fileProfile = Profile(
        id: 7,
        autoUpdateDuration: defaultUpdateDuration,
      );
      const urlProfile = Profile(
        id: 8,
        label: 'Remote',
        url: 'https://example.com/profile.yaml',
        autoUpdate: true,
        autoUpdateDuration: defaultUpdateDuration,
      );

      expect(fileProfile.type, ProfileType.file);
      expect(fileProfile.realAutoUpdate, false);
      expect(fileProfile.realLabel, '7');
      expect(fileProfile.fileName, '7.yaml');
      expect(fileProfile.updatingKey, 'profile_7');

      expect(urlProfile.type, ProfileType.url);
      expect(urlProfile.realAutoUpdate, true);
      expect(urlProfile.realLabel, 'Remote');
    });

    test('does not auto update on an interval that schedules nothing', () {
      const none = Profile(
        id: 9,
        url: 'https://example.com/profile.yaml',
        autoUpdateDuration: Duration.zero,
      );
      const backwards = Profile(
        id: 10,
        url: 'https://example.com/profile.yaml',
        autoUpdateDuration: Duration(minutes: -5),
      );

      expect(none.realAutoUpdate, false);
      expect(backwards.realAutoUpdate, false);
    });

    test('is due once the interval has passed or never ran', () {
      final now = DateTime.utc(2026, 10, 7, 12);
      final ran = Profile(
        id: 11,
        url: 'https://example.com/profile.yaml',
        autoUpdateDuration: const Duration(hours: 6),
        lastUpdateDate: now.subtract(const Duration(hours: 6)),
      );
      const never = Profile(
        id: 12,
        url: 'https://example.com/profile.yaml',
        autoUpdateDuration: Duration(hours: 6),
      );

      expect(ran.isAutoUpdateDue(now), true);
      expect(
        ran
            .copyWith(lastUpdateDate: now.subtract(const Duration(hours: 5)))
            .isAutoUpdateDue(now),
        false,
      );
      expect(never.isAutoUpdateDue(now), true);
    });
  });

  group('ProfilesExt', () {
    test('gets profile by id', () {
      const profiles = [
        Profile(id: 1, label: 'A', autoUpdateDuration: defaultUpdateDuration),
        Profile(id: 2, label: 'B', autoUpdateDuration: defaultUpdateDuration),
      ];

      expect(profiles.getProfile(2)?.label, 'B');
      expect(profiles.getProfile(3), isNull);
      expect(profiles.getProfile(null), isNull);
    });

    test('optimizes duplicate labels with incremented suffix', () {
      const profiles = [
        Profile(
          id: 1,
          label: 'Work',
          autoUpdateDuration: defaultUpdateDuration,
        ),
        Profile(
          id: 2,
          label: 'Work(1)',
          autoUpdateDuration: defaultUpdateDuration,
        ),
      ];
      const newProfile = Profile(
        id: 3,
        label: 'Work',
        autoUpdateDuration: defaultUpdateDuration,
      );

      expect(profiles.optimizeLabel(newProfile).label, 'Work(2)');
    });

    test('steps past a label an app-level proxy provider holds', () {
      const profiles = <Profile>[];
      const newProfile = Profile(
        id: 3,
        label: 'Shared nodes',
        autoUpdateDuration: defaultUpdateDuration,
      );

      expect(
        profiles
            .optimizeLabel(newProfile, reserved: const {'Shared nodes'})
            .label,
        'Shared nodes(1)',
      );
    });
  });

  group('ProfileRuleLinkExt', () {
    test('builds stable key from non-null parts', () {
      const link = ProfileRuleLink(
        profileId: 1,
        ruleId: 2,
        scene: RuleScene.added,
      );
      const globalLink = ProfileRuleLink(ruleId: 3);

      expect(link.key, '1_2_added');
      expect(globalLink.key, '3');
    });
  });
}
