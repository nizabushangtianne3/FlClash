import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/boot_record.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/system_dns.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Preferences {
  static Preferences? _instance;
  String? _lastSavedConfig;
  Completer<SharedPreferences?> sharedPreferencesCompleter = Completer();
  Completer<bool> isInitCompleter = Completer();

  Future<bool> get isInit async => isInitCompleter.future;

  Preferences._internal() {
    SharedPreferences.getInstance()
        .then((value) {
          sharedPreferencesCompleter.complete(value);
          isInitCompleter.complete(true);
        })
        .onError((_, _) {
          sharedPreferencesCompleter.complete(null);
          isInitCompleter.complete(false);
        });
  }

  factory Preferences() {
    _instance ??= Preferences._internal();
    return _instance!;
  }

  Future<int> getVersion() async {
    final preferences = await sharedPreferencesCompleter.future;
    return preferences?.getInt('version') ?? 0;
  }

  Future<void> setVersion(int version) async {
    final preferences = await sharedPreferencesCompleter.future;
    await preferences?.setInt('version', version);
  }

  Future<void> saveShareState(SharedState shareState) async {
    final preferences = await sharedPreferencesCompleter.future;
    await preferences?.setString('sharedState', json.encode(shareState));
  }

  Future<Map<String, Object?>?> getConfigMap() async {
    try {
      final preferences = await sharedPreferencesCompleter.future;
      final configString = preferences?.getString(configKey);
      _lastSavedConfig = null;
      if (configString == null) return null;
      final Map<String, Object?>? configMap = json.decode(configString);
      _lastSavedConfig = configString;
      return configMap;
    } catch (e) {
      commonPrint.log(
        'getConfigMap error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<Map<String, Object?>?> getClashConfigMap() async {
    try {
      final preferences = await sharedPreferencesCompleter.future;
      final clashConfigString = preferences?.getString(clashConfigKey);
      if (clashConfigString == null) return null;
      return json.decode(clashConfigString);
    } catch (e) {
      commonPrint.log(
        'getClashConfigMap error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> clearClashConfig() async {
    try {
      final preferences = await sharedPreferencesCompleter.future;
      await preferences?.remove(clashConfigKey);
      return;
    } catch (e) {
      commonPrint.log(
        'clearClashConfig error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return;
    }
  }

  Future<Config?> getConfig() async {
    final configMap = await getConfigMap();
    if (configMap == null) {
      return null;
    }
    return Config.fromJson(configMap);
  }

  Future<bool> saveConfig(Config config) async {
    final preferences = await sharedPreferencesCompleter.future;
    final encoded = json.encode(config);
    if (_lastSavedConfig == encoded) {
      return true;
    }
    final saved = await preferences?.setString(configKey, encoded) ?? false;
    if (saved) {
      _lastSavedConfig = encoded;
    }
    return saved;
  }

  Future<SystemDnsRecord?> getSystemDnsRecord() async {
    try {
      final sharedPreferencesIns = await sharedPreferencesCompleter.future;
      final raw = sharedPreferencesIns?.getString(systemDnsRecordKey);
      if (raw == null) {
        return null;
      }
      return SystemDnsRecord.fromJson(json.decode(raw));
    } catch (e) {
      commonPrint.log(
        'getSystemDnsRecord error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> saveSystemDnsRecord(SystemDnsRecord record) async {
    final sharedPreferencesIns = await sharedPreferencesCompleter.future;
    await sharedPreferencesIns?.setString(
      systemDnsRecordKey,
      json.encode(record),
    );
  }

  Future<void> clearSystemDnsRecord() async {
    final sharedPreferencesIns = await sharedPreferencesCompleter.future;
    await sharedPreferencesIns?.remove(systemDnsRecordKey);
  }

  Future<BootRecord?> getBootRecord() async {
    try {
      final sharedPreferencesIns = await sharedPreferencesCompleter.future;
      final raw = sharedPreferencesIns?.getString(bootRecordKey);
      if (raw == null) {
        return null;
      }
      return BootRecord.fromJson(json.decode(raw));
    } catch (e) {
      commonPrint.log(
        'getBootRecord error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> saveBootRecord(BootRecord record) async {
    final sharedPreferencesIns = await sharedPreferencesCompleter.future;
    await sharedPreferencesIns?.setString(bootRecordKey, json.encode(record));
  }

  Future<void> clearPreferences() async {
    final sharedPreferencesIns = await sharedPreferencesCompleter.future;
    await sharedPreferencesIns?.clear();
    _lastSavedConfig = null;
  }
}

final preferences = Preferences();
