import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';

/// 全局数据库实例。由 `main()` 负责在合适时机关闭（移动端通常随进程结束）。
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
