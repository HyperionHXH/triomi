import 'package:hive_ce/hive.dart';
import 'package:triomi/core/storage/preferences.dart';

/// 纯内存 Box：FakeAsync 区里不能有任何真实 IO（Hive 写盘会永久挂起）。
class MemBox implements Box<dynamic> {
  final Map<dynamic, dynamic> _map = <dynamic, dynamic>{};

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) => _map[key] ?? defaultValue;

  @override
  Future<void> put(dynamic key, dynamic value) async => _map[key] = value;

  @override
  Future<void> delete(dynamic key) async => _map.remove(key);

  @override
  Future<int> clear() async {
    final count = _map.length;
    _map.clear();
    return count;
  }

  @override
  bool containsKey(dynamic key) => _map.containsKey(key);

  @override
  Iterable<dynamic> get keys => _map.keys;

  @override
  Iterable<dynamic> get values => _map.values;

  @override
  bool get isOpen => true;

  @override
  String get name => 'settings';

  @override
  String? get path => null;

  @override
  Stream<BoxEvent> watch({dynamic key}) => const Stream<BoxEvent>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 不落盘、不挂起的设置存储。
Preferences memoryPreferences() => Preferences(MemBox());
