import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// 繁简转换方向。
enum ZhConversionMode { off, s2t, t2s }

/// 基于 OpenCC 字表的字符级繁简转换。
///
/// 数据来自 OpenCC 官方仓库（Apache-2.0）的 TSCharacters / STCharacters，
/// 格式为「源字\t候选1 候选2 …」，取第一个候选作为转换目标；一源多目标时
/// 单字映射会有歧义（如「乾」），这里接受该近似——词级转换表体积过大，
/// 对阅读场景收益有限。
class ZhConverter {
  ZhConverter._(this._s2t, this._t2s);

  final Map<String, String> _s2t;
  final Map<String, String> _t2s;

  static const String _stAsset = 'assets/opencc/STCharacters.txt';
  static const String _tsAsset = 'assets/opencc/TSCharacters.txt';

  static ZhConverter? _cached;

  /// 全局单例：字表约 100KB，进程内只解析一次。
  static Future<ZhConverter> instance({AssetBundle? bundle}) async {
    final cached = _cached;
    if (cached != null) return cached;
    final b = bundle ?? rootBundle;
    final s2t = await _parseDict(b, _stAsset);
    final t2s = await _parseDict(b, _tsAsset);
    return _cached = ZhConverter._(s2t, t2s);
  }

  /// 测试注入用。
  static ZhConverter fromMaps({
    required Map<String, String> s2t,
    required Map<String, String> t2s,
  }) => ZhConverter._(s2t, t2s);

  static Future<Map<String, String>> _parseDict(
    AssetBundle bundle,
    String asset,
  ) async {
    final text = await bundle.loadString(asset);
    final map = <String, String>{};
    for (final line in text.split('\n')) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final columns = line.split('\t');
      if (columns.length < 2 || columns[0].isEmpty) continue;
      final first = columns[1].trim().split(' ').first;
      if (first.isNotEmpty) map[columns[0]] = first;
    }
    return map;
  }

  /// 按方向转换文本；[mode] 为 off 时原样返回。
  String convert(String text, ZhConversionMode mode) {
    if (mode == ZhConversionMode.off || text.isEmpty) return text;
    final map = mode == ZhConversionMode.s2t ? _s2t : _t2s;
    if (map.isEmpty) return text;
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      buffer.write(map[ch] ?? ch);
    }
    return buffer.toString();
  }
}

/// JSON 便捷导入（测试构造字典用）。
Map<String, String> parseDictText(String text) {
  final map = <String, String>{};
  for (final line in LineSplitter.split(text)) {
    final columns = line.split('\t');
    if (columns.length < 2) continue;
    final first = columns[1].trim().split(' ').first;
    if (first.isNotEmpty) map[columns[0]] = first;
  }
  return map;
}
