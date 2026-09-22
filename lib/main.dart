import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'app.dart';
import 'core/storage/preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 设置存储（Hive）初始化完成后才启动 UI，避免页面读到未初始化的盒子。
  await Hive.initFlutter();
  final preferences = await Preferences.open();

  runApp(
    ProviderScope(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
      child: const TriomiApp(),
    ),
  );
}
