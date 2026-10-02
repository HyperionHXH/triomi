import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

/// 轻量键值设置存储（Hive）。
///
/// 只放设置项这类无关系的数据；业务数据（书架、进度、下载记录）一律进 drift。
class Preferences {
  Preferences(this._box);

  static const String boxName = 'settings';

  final Box<dynamic> _box;

  static Future<Preferences> open() async {
    final box = await Hive.openBox<dynamic>(boxName);
    return Preferences(box);
  }

  T? get<T>(String key) => _box.get(key) as T?;

  Future<void> set(String key, Object? value) => _box.put(key, value);

  Future<void> remove(String key) => _box.delete(key);

  Future<void> clear() => _box.clear();

  /// 导出全部设置（备份用）。只包含可 JSON 化的值。
  Map<String, Object?> exportAll() => <String, Object?>{
    for (final key in _box.keys)
      if (key is String) key: _box.get(key),
  };

  /// 导入设置：写入给定键值，返回写入条数。
  Future<int> importAll(Map<String, Object?> values) async {
    var count = 0;
    for (final entry in values.entries) {
      await _box.put(entry.key, entry.value);
      count += 1;
    }
    return count;
  }

  /// Restore a key subset after a failed multi-store import.
  /// [values] contains the previous values; [missing] contains keys that did
  /// not exist before the attempted import.
  Future<void> restoreSubset(
    Map<String, Object?> values,
    Set<String> missing,
  ) async {
    for (final key in missing) {
      await _box.delete(key);
    }
    for (final entry in values.entries) {
      await _box.put(entry.key, entry.value);
    }
  }
}

/// 在 `main()` 中通过 override 注入，保证页面读取设置时不会拿到未初始化的实例。
final preferencesProvider = Provider<Preferences>(
  (ref) =>
      throw UnimplementedError('preferencesProvider 必须在 main() 中 override'),
);
