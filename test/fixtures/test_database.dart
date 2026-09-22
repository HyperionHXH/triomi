import 'package:drift/native.dart';
import 'package:triomi/core/db/app_database.dart';

/// 测试用的内存数据库。
///
/// sqlite3 3.6 通过 native assets 提供原生库，`flutter test` 会一并构建，
/// 因此这里不需要手动指定动态库路径。
AppDatabase openTestDatabase() =>
    AppDatabase.forTesting(NativeDatabase.memory());
