/// Compiled, source-scoped gateway contracts. Rules cannot add native code or
/// obtain account secrets by declaring a feature; declarations only constrain
/// compatibility. Version these IDs when the native contract changes.
abstract final class SourceHostFeatures {
  static const supported = <String>{
    'jmcomic.api.v1',
    'jmcomic.image.v1',
    'picacomic.account.v1',
    'picacomic.account.v2',
    'picacomic.account.v3',
  };

  static Set<String> requiredFor(String id, Iterable<String> declared) => {
    ...declared,
    // Also protect rules published before explicit feature declarations.
    if (id == 'jmcomic') ...['jmcomic.api.v1', 'jmcomic.image.v1'],
    if (id == 'picacomic') 'picacomic.account.v1',
  };

  static List<String> parse(Object? value) {
    if (value == null) return const [];
    if (value is! List || value.length > 32) {
      throw const FormatException('requiresHost 必须是最多32项的能力数组');
    }
    final result = <String>[];
    for (final feature in value) {
      if (feature is! String ||
          feature.length > 100 ||
          !RegExp(r'^[a-z][a-z0-9]*(?:\.[a-z0-9]+)+$').hasMatch(feature) ||
          result.contains(feature)) {
        throw const FormatException('requiresHost 包含无效或重复的能力标识');
      }
      result.add(feature);
    }
    return List.unmodifiable(result);
  }

  static void requireSupported(
    String id,
    Iterable<String> declared, {
    Set<String> available = supported,
  }) {
    final missing = requiredFor(id, declared).difference(available);
    if (missing.isNotEmpty) {
      throw StateError('当前应用缺少原生网关能力：${missing.join(', ')}。请更新应用；仅更新JSON无法补齐。');
    }
  }
}
