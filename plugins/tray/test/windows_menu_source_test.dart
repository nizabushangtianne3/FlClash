import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

File _resolveSource(String relativePath) {
  final direct = File(relativePath);
  if (direct.existsSync()) {
    return direct;
  }
  final inPlugin = File('plugins/tray/$relativePath');
  if (inPlugin.existsSync()) {
    return inPlugin;
  }
  return direct;
}

// A Windows checkout keeps this source with CRLF, so compare on one ending.
String _readSource(String relativePath) =>
    _resolveSource(relativePath).readAsStringSync().replaceAll('\r\n', '\n');

String _body(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNonNegative, reason: signature);
  final end = source.indexOf('\n}\n', start);
  return source.substring(start, end);
}

void main() {
  late String pluginSource;

  setUpAll(() {
    pluginSource = _readSource('windows/tray_plugin.cpp');
  });

  test('windows menu clicks come from TrackPopupMenu, not WM_COMMAND', () {
    expect(pluginSource, contains('TPM_RETURNCMD'));
    expect(pluginSource, isNot(contains('WM_COMMAND')));
  });

  test('windows puts the detail in the accelerator column', () {
    expect(pluginSource, contains('StringAt(*entry, "detail")'));
    expect(pluginSource, contains("text += L'\\t';"));
  });

  test('windows show reports a failed icon load', () {
    expect(
      pluginSource,
      contains('''
    if (loaded == nullptr) {
      return false;
    }'''),
    );
  });

  test('windows show leaves an unchanged icon alone', () {
    expect(pluginSource, contains('state.icon_path != wanted_icon_path'));
    expect(pluginSource, contains('icon_changed ? NIF_ICON : 0'));
  });

  test('windows show rebuilds a changed menu only', () {
    expect(pluginSource, contains('!state.has_menu || state.menu != *items'));
  });

  test('windows hide forgets the cached icon and menu', () {
    final hide = _body(pluginSource, 'void TrayPlugin::Hide(');

    expect(hide, contains('TrayStates().erase(registrar_);'));
    expect(
      hide.indexOf('::DestroyIcon(icon_data_.hIcon);'),
      greaterThan(hide.indexOf('NIM_DELETE')),
    );
  });

  test('windows rejected show leaves the visible menu untouched', () {
    final show = _body(pluginSource, 'bool TrayPlugin::Show(');
    final lastRejection = show.lastIndexOf('return false;');
    final rebuild = show.indexOf('RebuildMenu(menu_, *items);');

    expect(lastRejection, isNonNegative);
    expect(rebuild, greaterThan(lastRejection));
  });

  test('windows retries an icon the shell refused at sign-in', () {
    final show = _body(pluginSource, 'bool TrayPlugin::Show(');

    expect(show, contains('ScheduleRestore();'));
    expect(show.trimRight(), endsWith('return true;'));
    expect(
      _body(pluginSource, 'void TrayPlugin::RestoreIcon('),
      contains('ApplyIcon(false) || ApplyIcon(true)'),
    );
    expect(pluginSource, contains('message == WM_TIMER'));
  });

  test('windows hide deletes an icon whose add may have landed', () {
    final hide = _body(pluginSource, 'void TrayPlugin::Hide(');

    expect(
      hide,
      contains('''
  if (icon_requested_) {
    ::Shell_NotifyIconW(NIM_DELETE, &icon_data_);
  }'''),
    );
    expect(
      hide.indexOf('icon_requested_ = false;'),
      greaterThan(hide.indexOf('NIM_DELETE')),
    );
  });
}
