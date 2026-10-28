import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'preferences.dart';

/// 敏感凭据的安全存储（Android Keystore / Windows DPAPI / iOS Keychain）。
///
/// 设计：初始化时把全部条目**预载进内存**，之后读写都是同步的——
/// 凭据数量只有个位数，预载开销可忽略；这样 [LkClient.securityKey] 这类
/// 同步 getter 不用改成 Future。写入/删除落盘成功后才更新缓存，失败向上抛。
///
/// 平台初始化失败时读取保持为空；成功写入的凭据仍可立即读取，
/// 旧 Hive 凭据只由显式迁移读取，不能作为追踪/WebDAV的运行时回退。
abstract class SecureStore {
  /// 预载全部条目；必须在任何 [get] 之前完成。
  Future<void> init();

  /// 同步读取已加载或成功写入的值；键不存在时返回 null。
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
      _ready = true;
    } catch (_) {
      // 保持未就绪：读取仍返回 null，之后可重试恢复平台安全存储。
    }
  }

  @override
  String? get(String key) => _cache[key];

  @override
  Future<void> set(String key, String value) async {
    await _storage.write(key: key, value: value);
    _cache[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    await _storage.delete(key: key);
    _cache.remove(key);
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

/// 旧凭据迁移标记；追踪/WebDAV 的升级迁移仍会检查明文残留。
const String kSecureMigratedKey = 'secure.migrated';

const String kWebDavConfigKey = 'sync.webdav.config';
const String kWebDavPasswordKey = 'sync.webdav.password';

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
/// 旧版本已迁移的其他凭据保持兼容；追踪凭据和嵌套 WebDAV 密码每次
/// 启动检查残留，只有安全写入成功后才删除明文，安全存储已有值优先。
Future<void> migrateCredentialsToSecureStore({
  required Preferences preferences,
  required SecureStore secureStore,
}) async {
  final alreadyMigrated = preferences.get<bool>(kSecureMigratedKey) == true;
  for (final key in kSensitiveHiveKeys) {
    if (alreadyMigrated && !key.startsWith('tracking.')) continue;
    final value = preferences.get<String>(key);
    if (value != null && value.isNotEmpty) {
      if (secureStore.get(key) == null) await secureStore.set(key, value);
      await preferences.remove(key);
    }
  }
  final raw = preferences.get<String>(kWebDavConfigKey);
  if (raw != null && raw.isNotEmpty) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Keep corrupt configuration intact for the settings repair path.
    }
    if (decoded is Map && decoded.containsKey('password')) {
      final password = '${decoded['password'] ?? ''}';
      if (secureStore.get(kWebDavPasswordKey) == null) {
        await secureStore.set(kWebDavPasswordKey, password);
      }
      final nonsecret = Map<String, Object?>.from(decoded)..remove('password');
      await preferences.set(kWebDavConfigKey, jsonEncode(nonsecret));
    }
  }
  await preferences.set(kSecureMigratedKey, true);
}
