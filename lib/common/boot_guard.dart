import 'dart:math';

import 'package:fl_clash/common/boot_record.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/enum/enum.dart';

class BootGuard {
  final bool _supported;
  final Future<BootRecord?> Function() _readRecord;
  final Future<void> Function(BootRecord record) _writeRecord;
  final Future<AppExitInfo?> Function() _readExitInfo;
  final Future<bool> Function() _readCrashReport;
  final int Function() _now;

  BootDecision _decision = const BootDecision();
  BootRecord? _lastRecord;

  BootGuard({
    bool? supported,
    Future<BootRecord?> Function()? readRecord,
    Future<void> Function(BootRecord record)? writeRecord,
    Future<AppExitInfo?> Function()? readExitInfo,
    Future<bool> Function()? readCrashReport,
    int Function()? now,
  }) : _supported = supported ?? system.isAndroid,
       _readRecord = readRecord ?? preferences.getBootRecord,
       _writeRecord = writeRecord ?? preferences.saveBootRecord,
       _readExitInfo = readExitInfo ?? system.lastExitInfo,
       _readCrashReport = readCrashReport ?? system.didCrashOnPreviousExecution,
       _now = now ?? _currentMilliseconds;

  static int _currentMilliseconds() => DateTime.now().millisecondsSinceEpoch;

  BootDecision get decision => _decision;

  Future<BootDecision> evaluate({
    required int? profileId,
    required bool crashlyticsEnabled,
  }) async {
    if (!_supported) {
      return _decision;
    }
    final recordFuture = _readRecordSafely();
    final exitInfoFuture = _readExitInfoSafely();
    final crashReportFuture = crashlyticsEnabled
        ? _readCrashReportSafely()
        : Future<bool>.value(false);
    final record = await recordFuture;
    final exitInfo = await exitInfoFuture;
    final crashReported = await crashReportFuture;
    final decision = resolveBootDecision(
      record: record,
      exitInfo: exitInfo,
      crashReported: crashReported,
    );
    if (decision.isDegraded) {
      commonPrint.log(
        'Previous launch did not finish: $decision',
        logLevel: LogLevel.warning,
      );
    }
    await _tryWriteRecord(
      BootRecord(
        stage: BootStage.starting,
        profileId: decision.recovery == BootRecovery.clearProfile
            ? null
            : profileId,
        startedAt: _now(),
        failureCount: decision.failureCount,
        lastFailedProfileId:
            decision.failedProfileId ?? record?.lastFailedProfileId,
        handledExitAt: max(
          record?.handledExitAt ?? 0,
          exitInfo?.timestamp ?? 0,
        ),
      ),
    );
    _decision = decision;
    return decision;
  }

  Future<void> markRunning() async {
    if (!_supported) {
      return;
    }
    final record = _lastRecord ?? await _readRecordSafely();
    if (record == null) {
      return;
    }
    await _tryWriteRecord(
      BootRecord(
        stage: BootStage.running,
        profileId: record.profileId,
        startedAt: record.startedAt,
        failureCount: _decision.isDegraded ? record.failureCount : 0,
        lastFailedProfileId: record.lastFailedProfileId,
        handledExitAt: record.handledExitAt,
      ),
    );
  }

  Future<void> markClosed() async {
    if (!_supported) {
      return;
    }
    final record = _lastRecord ?? await _readRecordSafely();
    if (record == null) {
      return;
    }
    await _tryWriteRecord(
      BootRecord(
        profileId: record.profileId,
        startedAt: record.startedAt,
        lastFailedProfileId: record.lastFailedProfileId,
        handledExitAt: record.handledExitAt,
      ),
    );
  }

  Future<BootRecord?> _readRecordSafely() async {
    try {
      return await _readRecord();
    } catch (error) {
      _logFailure('read record', error);
      return null;
    }
  }

  Future<AppExitInfo?> _readExitInfoSafely() async {
    try {
      return await _readExitInfo();
    } catch (error) {
      _logFailure('read exit info', error);
      return null;
    }
  }

  Future<bool> _readCrashReportSafely() async {
    try {
      return await _readCrashReport();
    } catch (error) {
      _logFailure('read crash report', error);
      return false;
    }
  }

  Future<void> _tryWriteRecord(BootRecord record) async {
    try {
      await _writeRecord(record);
      _lastRecord = record;
    } catch (error) {
      _logFailure('write record', error);
    }
  }

  void _logFailure(String action, Object error) {
    commonPrint.log(
      'Boot guard $action failed: $error',
      logLevel: LogLevel.warning,
    );
  }
}

final bootGuard = BootGuard();
