import 'package:drift/drift.dart';

import '../models/media_type.dart';

/// 本地数据库表定义（对齐 PROJECT_SPEC 第 5 章）。
///
/// 核心不变量（继承自 Mixn）：业务键一律是 `(sourceId, remoteId)` 复合键，
/// 禁止只用 remoteId —— 所以下面凡是内容相关表，主键都包含 sourceId。
///
/// 说明：`sourceId` / `remoteId` 用 `(sourceId, remoteId)` 语义命名，
/// 在章节、历史、下载等表里复用同一对列名，保持可读性与一致性。

/// 内容来源（内置适配器 + JS 扩展源）。
@DataClassName('SourceRow')
class Sources extends Table {
  /// 稳定本地标识，非站点数字 ID。
  TextColumn get id => text()();

  TextColumn get name => text()();

  /// 该源提供的内容形态，见 [MediaType]。
  TextColumn get type => textEnum<MediaType>()();

  TextColumn get lang => text().withDefault(const Constant('zh'))();

  /// 来源类型，见 [SourceKind]。
  TextColumn get kind => textEnum<SourceKind>()();

  /// 扩展源版本号（内置源为 null）。
  TextColumn get version => text().nullable()();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// 规则正文：声明式规则存 JSON，JS 扩展源存脚本源码（内置源为 null）。
  TextColumn get ruleText => text().nullable()();

  /// 扩展源所属仓库地址。
  TextColumn get repoUrl => text().nullable()();

  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// 作品（一部番剧 / 一部漫画 / 一本小说）。
@DataClassName('MediaItemRow')
class MediaItems extends Table {
  TextColumn get sourceId => text()();

  TextColumn get remoteId => text()();

  TextColumn get type => textEnum<MediaType>()();

  TextColumn get title => text()();

  TextColumn get coverUrl => text().nullable()();

  TextColumn get author => text().nullable()();

  TextColumn get description => text().nullable()();

  /// 标签 / 题材，JSON 数组字符串。
  TextColumn get tagsJson => text().nullable()();

  RealColumn get rating => real().nullable()();

  /// 连载中 / 已完结 / 未知（原样保留来源文案）。
  TextColumn get status => text().nullable()();

  /// 详情页扩展字段（同书版本、关联推荐等），JSON。
  TextColumn get detailJson => text().nullable()();

  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{sourceId, remoteId};
}

/// 章节 / 剧集。
///
/// 小说沿用 Mixn 的「卷 → 章」两级结构：卷名存在 [volumeTitle]，
/// 番剧与漫画该列为 null。
@DataClassName('ChapterRow')
class Chapters extends Table {
  TextColumn get sourceId => text()();

  TextColumn get remoteId => text()();

  /// 所属作品的外键（复合）。
  TextColumn get itemSourceId => text()();

  TextColumn get itemRemoteId => text()();

  TextColumn get title => text()();

  /// 章节号，支持 4.5 / 4.a 这类小数与字母后缀（参考 Mihon 的章节号识别）。
  RealColumn get number => real().nullable()();

  /// 排序用序号，避免章节号缺失时顺序错乱。
  IntColumn get sortIndex => integer().withDefault(const Constant(0))();

  TextColumn get volumeTitle => text().nullable()();

  DateTimeColumn get releaseDate => dateTime().nullable()();

  /// 付费 / 锁定章节：只标注，不绕过、不缓存、不导出。
  BoolColumn get locked => boolean().withDefault(const Constant(false))();

  /// 正文 / 图片列表 / 播放线路，JSON。
  TextColumn get contentJson => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{sourceId, remoteId};
}

/// 书架条目（用户已收藏的内容 + 进度）。
@DataClassName('LibraryEntryRow')
class LibraryEntries extends Table {
  TextColumn get sourceId => text()();

  TextColumn get remoteId => text()();

  TextColumn get type => textEnum<MediaType>()();

  /// 看到第几章（番剧为集数）。
  RealColumn get progress => real().withDefault(const Constant<double>(0))();

  /// 用户评分（0~10，未评为 null）。
  IntColumn get score => integer().nullable()();

  /// 在看 / 想看 / 看过 / 搁置 / 抛弃（对齐 Bangumi 五态）。
  TextColumn get status => text().withDefault(const Constant('doing'))();

  BoolColumn get pinned => boolean().withDefault(const Constant(false))();

  /// 来源报告的未读/新增章数（LK 有此能力，其他源靠刷新对比）。
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get addedAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{sourceId, remoteId};
}

/// 书架分类。
@DataClassName('CategoryRow')
class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get name => text()();

  IntColumn get sortIndex => integer().withDefault(const Constant(0))();
}

/// 书架条目 ↔ 分类 多对多。
@DataClassName('LibraryCategoryLinkRow')
class LibraryCategoryLinks extends Table {
  TextColumn get sourceId => text()();

  TextColumn get remoteId => text()();

  IntColumn get categoryId => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    sourceId,
    remoteId,
    categoryId,
  };
}

/// 阅读历史。
@DataClassName('HistoryRow')
class Histories extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get sourceId => text()();

  TextColumn get remoteId => text()();

  TextColumn get chapterSourceId => text()();

  TextColumn get chapterRemoteId => text()();

  /// 位置：番剧为秒，漫画为页，小说为段落偏移。
  RealColumn get position => real().withDefault(const Constant<double>(0))();

  /// 产生该记录的设备标识（多设备同步时用于冲突判断）。
  TextColumn get device => text().nullable()();

  DateTimeColumn get visitedAt => dateTime()();

  /// 无痕模式产生的记录不参与同步。
  BoolColumn get incognito => boolean().withDefault(const Constant(false))();
}

/// 下载任务与已下载内容。
@DataClassName('DownloadRow')
class Downloads extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get sourceId => text()();

  TextColumn get remoteId => text()();

  TextColumn get chapterSourceId => text()();

  TextColumn get chapterRemoteId => text()();

  /// queued / running / done / failed。
  TextColumn get status => text()();

  RealColumn get progress => real().withDefault(const Constant<double>(0))();

  TextColumn get path => text().nullable()();

  TextColumn get errorMessage => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get finishedAt => dateTime().nullable()();
}

/// 追踪服务绑定（Bangumi / AniList / MyAnimeList）。
@DataClassName('TrackBindRow')
class TrackBinds extends Table {
  TextColumn get sourceId => text()();

  TextColumn get remoteId => text()();

  /// bangumi / anilist / mal。
  TextColumn get service => text()();

  /// 远端条目 ID。
  TextColumn get remoteTrackId => text()();

  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    sourceId,
    remoteId,
    service,
  };
}
