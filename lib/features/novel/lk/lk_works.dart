/// 轻之国度「发布管理」的数据契约（D27 adapter seam）。
///
/// 站点的作品管理接口在 `LkClient` 里**尚无已验证的契约**——按工作单要求，
/// 这里只定义页面所需的形状（作品列表 + 分页），真实端点接入由 Codex 完成
/// （届时实现 [LkWorksRepository] 并替换 [lkWorksRepositoryProvider] 的默认值，
/// 页面代码不需要改动）。不猜真实接口路径与字段名。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';

/// 一部已发布的作品（列表项）。
class LkWork {
  const LkWork({
    required this.id,
    required this.title,
    this.updatedAt,
    this.chapterCount,
  });

  final String id;
  final String title;

  /// 站点返回的最近更新时间（原样展示，格式由站点决定）。
  final String? updatedAt;

  final int? chapterCount;
}

/// 一页作品列表；[hasMore] 决定是否继续加载下一页。
class LkWorksPageResult {
  const LkWorksPageResult({required this.items, required this.hasMore});

  final List<LkWork> items;
  final bool hasMore;
}

/// 发布管理的数据源 seam。
abstract class LkWorksRepository {
  /// 拉取第 [page] 页（从 1 开始）。失败抛 [SourceException]。
  Future<LkWorksPageResult> fetchPage(int page);
}

/// 默认实现：真实接口契约未定义前的占位。
///
/// 页面会把它呈现为可读的错误态（而不是崩溃或假空列表），提示能力尚未接入。
class LkWorksUnavailable implements LkWorksRepository {
  const LkWorksUnavailable();

  @override
  Future<LkWorksPageResult> fetchPage(int page) async {
    throw const SourceException(
      sourceId: 'light-novel-kingdom',
      type: SourceErrorType.parse,
      message: '发布管理的站点接口尚未接入',
    );
  }
}

/// 页面读取的数据源；测试用 [ProviderScope.overrides] 注入替身。
final Provider<LkWorksRepository> lkWorksRepositoryProvider =
    Provider<LkWorksRepository>((ref) => const LkWorksUnavailable());
