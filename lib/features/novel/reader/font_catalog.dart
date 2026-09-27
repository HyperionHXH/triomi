import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// 在线字体目录条目（T7-5）。
@immutable
class FontCatalogEntry {
  const FontCatalogEntry({
    required this.name,
    required this.fileName,
    required this.url,
    required this.license,
    this.note,
  });

  final String name;
  final String fileName;
  final String url;
  final String license;
  final String? note;

  static FontCatalogEntry fromJson(Map<Object?, Object?> json) {
    final name = json['name']?.toString() ?? '';
    final fileName = json['fileName']?.toString() ?? '';
    final url = json['url']?.toString() ?? '';
    if (name.isEmpty || fileName.isEmpty || url.isEmpty) {
      throw const FormatException('字体目录条目缺少 name / fileName / url');
    }
    return FontCatalogEntry(
      name: name,
      fileName: fileName,
      url: url,
      license: json['license']?.toString() ?? '',
      note: json['note']?.toString(),
    );
  }
}

/// 随包目录资产路径。
const String fontCatalogAsset = 'assets/fonts/catalog.json';

/// 解析目录 JSON（格式不对的条目跳过，不让一条坏数据毁掉整个目录）。
List<FontCatalogEntry> parseFontCatalog(String jsonText) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException {
    throw const FormatException('字体目录不是合法 JSON');
  }
  if (decoded is! List) {
    throw const FormatException('字体目录必须是数组');
  }
  final entries = <FontCatalogEntry>[];
  for (final node in decoded) {
    if (node is! Map) continue;
    try {
      entries.add(FontCatalogEntry.fromJson(node));
    } on FormatException {
      continue;
    }
  }
  return entries;
}

/// 从资产包加载目录；[bundle] 可注入（测试用）。
Future<List<FontCatalogEntry>> loadFontCatalog([AssetBundle? bundle]) async {
  final text = await (bundle ?? rootBundle).loadString(fontCatalogAsset);
  return parseFontCatalog(text);
}
