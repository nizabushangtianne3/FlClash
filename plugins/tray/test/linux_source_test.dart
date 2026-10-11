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

void main() {
  late String pluginSource;

  setUpAll(() {
    pluginSource = _readSource('linux/tray_plugin.cc');
  });

  test('linux show reports an icon it cannot find', () {
    expect(
      pluginSource,
      contains('''
  if (id == nullptr || icon_path == nullptr ||
      !g_file_test(icon_path, G_FILE_TEST_EXISTS)) {
    return respond(false);
  }'''),
    );
  });

  test('linux setTitle refuses without an indicator', () {
    expect(
      pluginSource,
      contains('''
  if (self->indicator == nullptr) {
    return respond(false);
  }'''),
    );
  });

  test('linux hide releases the indicator', () {
    expect(pluginSource, contains('g_object_unref(self->indicator);'));
  });

  test('linux answers an unknown method with not implemented', () {
    expect(pluginSource, contains('fl_method_not_implemented_response_new()'));
  });

  test('linux builds every entry kind and only dispatches a leaf click', () {
    expect(pluginSource, contains('strcmp(type, "separator") == 0'));
    expect(pluginSource, contains('strcmp(type, "checkbox") == 0'));
    expect(pluginSource, contains('strcmp(type, "submenu") == 0'));
    expect(
      pluginSource,
      contains('gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item),'),
    );
    expect(pluginSource, contains('bool_value(entry, "enabled", true)'));
    expect(pluginSource, contains('dispatches = false;'));
  });
}
