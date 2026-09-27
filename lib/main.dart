import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/storage/preferences.dart';
import 'core/storage/secure_store.dart';
import 'features/schedule/data/background_update_check.dart';

/// 后台更新检查的引擎入口（T7-7）。
///
/// 必须声明在应用入口库里：原生侧（JobScheduler）按名字解析入口时只在
/// 入口库中查找。实现见 [runBackgroundUpdateCheckEntrypoint]。
@pragma('vm:entry-point')
Future<void> backgroundUpdateCheck() => runBackgroundUpdateCheckEntrypoint();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 播放器内核（libmpv）的原生初始化；必须在 runApp 之前。
  MediaKit.ensureInitialized();

  // 设置存储（Hive）初始化完成后才启动 UI，避免页面读到未初始化的盒子。
  await Hive.initFlutter();
  final preferences = await Preferences.open();

  // 凭据安全存储：预载后立刻做一次性迁移（幂等），
  // 必须在任何客户端读会话 / token 之前完成。
  final secureStore = FlutterSecureStore();
  await secureStore.init();
  await migrateCredentialsToSecureStore(
    preferences: preferences,
    secureStore: secureStore,
  );

  runApp(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        secureStoreProvider.overrideWithValue(secureStore),
      ],
      child: const TriomiApp(),
    ),
  );
}
