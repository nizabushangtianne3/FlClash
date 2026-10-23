import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';

import 'dart:math';

extension StringExtension on String {
  bool get isUrl => webUri != null;

  Uri? get webUri {
    final uri = Uri.tryParse(this) ?? _parseWithBareAtInUserInfo(this);
    return uri != null &&
            (uri.scheme == 'http' ||
                uri.scheme == 'https' ||
                uri.scheme == 'ftp') &&
            uri.host.isNotEmpty
        ? uri
        : null;
  }

  bool get isShareLink {
    final index = indexOf('://');
    return index > 0 &&
        length > index + 3 &&
        !contains('\n') &&
        shareLinkSchemes.contains(substring(0, index).toLowerCase());
  }

  dynamic get splitByMultipleSeparators {
    final parts = <String>[];
    var start = 0;
    for (var index = 0; index < length; index++) {
      final codeUnit = codeUnitAt(index);
      if (codeUnit != 0x2C && codeUnit != 0x20 && codeUnit != 0x3B) {
        continue;
      }
      if (index > start) {
        parts.add(substring(start, index));
      }
      start = index + 1;
    }
    if (start < length) {
      parts.add(substring(start));
    }

    return parts.length > 1 ? parts : this;
  }

  String get countryFlagEmoji {
    const upperA = 0x41;
    const upperZ = 0x5A;
    const lowerA = 0x61;
    const lowerZ = 0x7A;
    if (length != 2) {
      return this;
    }
    final first = codeUnitAt(0);
    final second = codeUnitAt(1);
    final firstUpper = first >= lowerA && first <= lowerZ
        ? first - 0x20
        : first;
    final secondUpper = second >= lowerA && second <= lowerZ
        ? second - 0x20
        : second;
    if (firstUpper < upperA ||
        firstUpper > upperZ ||
        secondUpper < upperA ||
        secondUpper > upperZ) {
      return this;
    }
    const regionalIndicatorA = 0x1F1E6;
    return String.fromCharCodes([
      firstUpper - upperA + regionalIndicatorA,
      secondUpper - upperA + regionalIndicatorA,
    ]);
  }

  String safeSubstring(int start, [int? end]) {
    if (isEmpty) return '';
    final safeStart = start.clamp(0, length);
    if (end == null) {
      return substring(safeStart);
    }
    final safeEnd = end.clamp(safeStart, length);
    return substring(safeStart, safeEnd);
  }

  List<int> get encodeUtf16LeWithBom {
    final byteData = ByteData(length * 2);
    final bom = [0xFF, 0xFE];
    for (int i = 0; i < length; i++) {
      final int charCode = codeUnitAt(i);
      byteData.setUint16(i * 2, charCode, Endian.little);
    }
    return bom + byteData.buffer.asUint8List();
  }

  Uint8List? get getBase64 {
    const marker = 'base64,';
    final markerIndex = indexOf(marker);
    final realValue = markerIndex < 0
        ? ''
        : substring(markerIndex + marker.length);
    if (realValue.isEmpty) {
      return null;
    }
    try {
      return base64.decode(realValue);
    } catch (e) {
      commonPrint.log(
        'invalid base64 data ${e.toString()}',
        logLevel: LogLevel.debug,
      );
      return null;
    }
  }

  bool get isSvg {
    if (startsWith('data:')) {
      return startsWith('data:image/svg+xml');
    }
    return (Uri.tryParse(this)?.path ?? this).toLowerCase().endsWith('.svg');
  }

  String toMd5() {
    final bytes = utf8.encode(this);
    return md5.convert(bytes).toString();
  }

  Future<T> decodeJson<T>() async {
    const thresholdLimit = 51200;
    if (length < thresholdLimit) {
      return json.decode(this);
    } else {
      return decodeJSONTask<T>(this);
    }
  }

  String? get value {
    if (isEmpty) {
      return null;
    }
    return this;
  }

  String take(int maxLength) {
    return length <= maxLength ? this : substring(0, maxLength);
  }

  String get fileStem {
    final dot = lastIndexOf('.');
    return dot > 0 ? substring(0, dot) : this;
  }

  String get urlFileName {
    final segments = Uri.tryParse(this)?.pathSegments ?? const [];
    return segments.lastWhere(
      (segment) => segment.isNotEmpty,
      orElse: () => '',
    );
  }
}

Uri? _parseWithBareAtInUserInfo(String url) {
  final schemeEnd = url.indexOf('://');
  if (schemeEnd == -1) return null;
  final authorityStart = schemeEnd + 3;
  final pathStart = _pathOrFragmentStart(url, authorityStart);
  final authorityEnd = pathStart == -1 ? url.length : pathStart;
  final at = url.lastIndexOf('@', authorityEnd - 1);
  if (at <= authorityStart) return null;
  final userInfo = url.substring(authorityStart, at).replaceAll('@', '%40');
  return Uri.tryParse(
    '${url.substring(0, authorityStart)}$userInfo${url.substring(at)}',
  );
}

int _pathOrFragmentStart(String url, int start) {
  for (var index = start; index < url.length; index++) {
    final codeUnit = url.codeUnitAt(index);
    if (codeUnit == 0x2F || codeUnit == 0x3F || codeUnit == 0x23) {
      return index;
    }
  }
  return -1;
}

final _labelCounter = RegExp(r'\((\d{1,9})\)$');

String uniqueLabelFor(
  String name, {
  required String fallback,
  required bool Function(String label) taken,
}) {
  const maxLength = TextInputLimits.name;
  final label = name.trim().takeFirstValid([fallback]).take(maxLength).trim();
  if (!taken(label)) {
    return label;
  }
  final counter = _labelCounter.firstMatch(label);
  final stem = counter == null ? label : label.substring(0, counter.start);
  for (var index = int.parse(counter?[1] ?? '0') + 1; ; index++) {
    final suffix = '($index)';
    final candidate = stem.take(maxLength - suffix.length) + suffix;
    if (!taken(candidate)) {
      return candidate;
    }
  }
}

extension StringNullExt on String? {
  String takeFirstValid(List<String?> others, {String defaultValue = ''}) {
    if (this != null && this!.trim().isNotEmpty) return this!.trim();

    for (final s in others) {
      if (s != null && s.trim().isNotEmpty) {
        return s.trim();
      }
    }
    return defaultValue;
  }
}

String generateRandomString({int minLength = 10, int maxLength = 100}) {
  const latinChars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final random = Random();

  final int length = minLength + random.nextInt(maxLength - minLength + 1);

  String result = '';
  for (int i = 0; i < length; i++) {
    if (random.nextBool()) {
      result += String.fromCharCode(
        0x4E00 + random.nextInt(0x9FA5 - 0x4E00 + 1),
      );
    } else {
      result += latinChars[random.nextInt(latinChars.length)];
    }
  }

  return result;
}

String generateRandomSecret(int length) {
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final random = Random.secure();
  return String.fromCharCodes(
    Iterable.generate(
      length,
      (_) => chars.codeUnitAt(random.nextInt(chars.length)),
    ),
  );
}
