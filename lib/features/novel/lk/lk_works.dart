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
import '../../../core/source/source_providers.dart';
import '../data/lk/lk_source.dart';

/// 一部已发布的作品（列表项）。
class LkWork {
  const LkWork({
    required this.id,
    required this.title,
    this.updatedAt,
    this.chapterCount,
    this.coverUrl,
    this.author,
    this.summary,
    this.status,
    this.reviewStatus,
    this.reviewText,
    this.volumeCount,
    this.wordCount,
  });

  final String id;
  final String title;

  /// 站点返回的最近更新时间（原样展示，格式由站点决定）。
  final String? updatedAt;

  final int? chapterCount;
  final String? coverUrl;
  final String? author;
  final String? summary;
  final String? status;
  final String? reviewStatus;
  final String? reviewText;
  final int? volumeCount;
  final int? wordCount;
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

/// 旧版占位实现，保留用于兼容性测试；生产 provider 使用
/// [LkWorksRepositoryAdapter]。
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

/// 生产适配器：从来源注册表取出已启用的真实 LK 来源。
class LkWorksRepositoryAdapter implements LkWorksRepository {
  const LkWorksRepositoryAdapter(this.ref);

  final Ref ref;

  @override
  Future<LkWorksPageResult> fetchPage(int page) async {
    final snapshot = await ref.read(sourcesProvider.future);
    final entry = snapshot.entries
        .where((candidate) => candidate.descriptor.id == LkSource.id)
        .firstOrNull;
    if (entry == null || !entry.enabled || entry.source is! LkSource) {
      throw const SourceException(
        sourceId: LkSource.id,
        type: SourceErrorType.parse,
        message: '轻之国度来源未启用',
      );
    }
    final result = await (entry.source as LkSource).publishedWorks(page: page);
    return LkWorksPageResult(
      items: <LkWork>[
        for (final item in result.items)
          LkWork(
            id: '${item.id}',
            title: item.title,
            updatedAt: item.updatedAt.isEmpty ? null : item.updatedAt,
            chapterCount: item.chapterCount > 0 ? item.chapterCount : null,
            coverUrl: item.coverUrl,
            author: item.author.isEmpty ? null : item.author,
            summary: item.summary.isEmpty ? null : item.summary,
            status: item.status.isEmpty ? null : item.status,
            reviewStatus: item.reviewStatus.isEmpty ? null : item.reviewStatus,
            reviewText: item.reviewText.isEmpty ? null : item.reviewText,
            volumeCount: item.volumeCount > 0 ? item.volumeCount : null,
            wordCount: item.wordCount > 0 ? item.wordCount : null,
          ),
      ],
      hasMore: result.hasMore,
    );
  }
}

/// 页面读取的数据源；测试用 [ProviderScope.overrides] 注入替身。
final Provider<LkWorksRepository> lkWorksRepositoryProvider =
    Provider<LkWorksRepository>(LkWorksRepositoryAdapter.new);
