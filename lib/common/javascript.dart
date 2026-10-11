import 'dart:convert';

import 'package:fl_clash/common/exception.dart';
import 'package:flutter/foundation.dart';
import 'package:rust_api/rust_api.dart';

typedef ScriptEvaluator =
    Future<String> Function({required String script, required String config});

const _notAConfigMessage = 'script did not return a configuration object';

@visibleForTesting
ScriptEvaluator scriptEvaluator = evaluateScript;

Future<Map<String, dynamic>> handleEvaluate(
  String scriptContent,
  Map<String, dynamic> config,
) async {
  if (config['proxy-providers'] == null) {
    config['proxy-providers'] = {};
  }
  final String result;
  try {
    result = await scriptEvaluator(
      script: scriptContent,
      config: json.encode(config),
    );
  } catch (e) {
    throw MessageException(e.toString());
  }
  final Object? decoded;
  try {
    decoded = json.decode(result);
  } on FormatException {
    throw const MessageException(_notAConfigMessage);
  }
  if (decoded is! Map<String, dynamic>) {
    throw const MessageException(_notAConfigMessage);
  }
  return decoded;
}
