import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'preferences.dart';

/// 敏感凭据的安全存储（Android Keystore / Windows DPAPI）。
///
/// 设计：初始化时把全部条目**预载进内存**，之后读写都是同步的——
/// 凭据数量只有个位数，预载开销可忽略；这样 [LkClient.securityKey] 这类
/// 同步 getter 不用改成 Future。写操作先更新内存再异步落盘，读永远命中缓存。
///
/// 平台实现失败（Keystore 初始化异常等）时缓存保持为空：读取方会走
/// Hive 回退，不崩溃。
abstract class SecureStore {
  /// 预载全部条目；必须在任何 [get] 之前完成。
  Future<void> init();

  /// 同步读取；未初始化或键不存在时返回 null。
  String? get(String key);

  Future<void> set(String key, String value);

  Future<void> remove(String key);

  /// 全部已加载的键（迁移与排错用）。
  Set<String> get keys;
}

/// 基于 flutter_secure_storage 的实现。
class FlutterSecureStore implements SecureStore {
  FlutterSecureStore();

  final Map<String, String> _cache = <String, String>{};
  bool _ready = false;

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    // Android 用 EncryptedSharedPreferences（Keystore 加密）。
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<void> init() async {
    if (_ready) return;
    try {
      _cache.addAll(await _storage.readAll());
    } catch (_) {
      // 平台层失败：保持空缓存，调用方走 Hive 回退。
    }
    _ready = true;
  }

  @override
  String? get(String key) => _ready ? _cache[key] : null;

  @override
  Future<void> set(String key, String value) async {
    _cache[key] = value;
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      // 落盘失败不影响本次会话内的读取；下次启动会走迁移重试。
    }
  }

  @override
  Future<void> remove(String key) async {
    _cache.remove(key);
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // 同上。
    }
  }

  @override
  Set<String> get keys => _cache.keys.toSet();
}

/// 纯内存实现（测试用）：接口与语义一致，不落任何盘。
class MemorySecureStore implements SecureStore {
  final Map<String, String> _map = <String, String>{};

  @override
  Future<void> init() async {}

  @override
  String? get(String key) => _map[key];

  @override
  Future<void> set(String key, String value) async => _map[key] = value;

  @override
  Future<void> remove(String key) async => _map.remove(key);

  @override
  Set<String> get keys => _map.keys.toSet();
}

/// 在 `main()` 中通过 override 注入（与 preferencesProvider 同模式）。
final secureStoreProvider = Provider<SecureStore>(
  (ref) =>
      throw UnimplementedError('secureStoreProvider 必须在 main() 中 override'),
);

// ---------------------------------------------------------------- 一次性迁移

/// 启动时迁移完成标记：置位后跳过（幂等）。
const String kSecureMigratedKey = 'secure.migrated';

/// Hive 里的明文凭据键：迁移到 SecureStore 后从 Hive 删除。
///
/// 内容不进备份（备份的 _isSensitive 过滤 + SecureStore 本身不在 Hive）。
const List<String> kSensitiveHiveKeys = <String>[
  // LK 登录会话。
  'lk.securityKey',
  // 弹弹play 应用密钥与用户 token（appId 非机密，留在 Hive）。
  'danmaku.dandanplay.appSecret',
  'danmaku.dandanplay.token',
  // 追踪服务的访问 token（Bangumi / AniList）。
  'tracking.bangumi.token',
  'tracking.anilist.token',
];

/// 把 Hive 里的明文凭据迁到 SecureStore（幂等，启动时调用一次）。
///
/// 只有值非空的键才会动；迁移过的键从 Hive 删除，之后读取方走
/// 「先 SecureStore、后 Hive」的回退路径（兼容迁移前备份的旧值）。
Future<void> migrateCredentialsToSecureStore({
  required Preferences preferences,
  required SecureStore secureStore,
}) async {
  if (preferences.get<bool>(kSecureMigratedKey) == true) return;
  for (final key in kSensitiveHiveKeys) {
    final value = preferences.get<String>(key);
    if (value != null && value.isNotEmpty) {
      await secureStore.set(key, value);
      await preferences.remove(key);
    }
  }
  await preferences.set(kSecureMigratedKey, true);
}
