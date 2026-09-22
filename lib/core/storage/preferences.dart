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
}

/// 在 `main()` 中通过 override 注入，保证页面读取设置时不会拿到未初始化的实例。
final preferencesProvider = Provider<Preferences>(
  (ref) =>
      throw UnimplementedError('preferencesProvider 必须在 main() 中 override'),
);
