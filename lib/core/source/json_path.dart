/// 极简点路径取值，用于 JSON 响应格式的来源（如 Bangumi 开放接口）。
///
/// 支持：`data`、`images.large`、`data.0.name`。
/// 不支持带 `.` 的键名与通配符——规则里真的需要时应当改用 HTML 模式。
Object? jsonPick(Object? root, String path) {
  if (path.trim().isEmpty) return root;
  Object? current = root;
  for (final segment in path.split('.')) {
    if (segment.isEmpty) continue;
    if (current == null) return null;
    if (current is List) {
      final index = int.tryParse(segment);
      if (index == null || index < 0 || index >= current.length) return null;
      current = current[index];
      continue;
    }
    if (current is Map) {
      current = current[segment];
      continue;
    }
    return null;
  }
  return current;
}

/// 取值并转成字符串；null 与空串都返回 null。
String? jsonPickString(Object? root, String path) {
  final value = jsonPick(root, path);
  if (value == null) return null;
  if (value is String) return value.trim().isEmpty ? null : value.trim();
  return value.toString();
}

/// 把 JSON 数组节点取出来（列表解析用）。
List<Object?> jsonPickList(Object? root, String path) {
  final value = jsonPick(root, path);
  if (value is List) return value;
  return const <Object?>[];
}
