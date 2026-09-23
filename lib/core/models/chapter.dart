/// 播放线路（番剧多线路，对齐 Kazumi 的多视频源）。
class PlaySource {
  const PlaySource({required this.name, required this.url});

  final String name;
  final String url;
}

/// 章节正文内容：按内容形态取其中一种。
class ChapterContent {
  const ChapterContent({
    this.images = const <String>[],
    this.text,
    this.html,
    this.playSources = const <PlaySource>[],
    this.danmakuUrl,
  });

  /// 漫画：图片地址列表。
  final List<String> images;

  /// 小说：纯文本正文（与 [html] 二选一，html 优先）。
  final String? text;

  /// 小说：HTML 正文（含插图段落，如轻之国度的 body_html）。
  final String? html;

  /// 番剧：播放线路列表。
  final List<PlaySource> playSources;

  /// 番剧：弹幕数据地址（返回弹弹play 格式的 JSON）。
  final String? danmakuUrl;

  bool get isEmpty =>
      images.isEmpty &&
      (text == null || text!.isEmpty) &&
      (html == null || html!.isEmpty) &&
      playSources.isEmpty &&
      danmakuUrl == null;
}

/// 章节 / 剧集。
///
/// 小说沿用 Mixn 的「卷 → 章」两级结构：[volumeTitle] 有值时表示该章属于某一卷；
/// 番剧与漫画为 null。
class Chapter {
  const Chapter({
    required this.sourceId,
    required this.remoteId,
    required this.title,
    this.url,
    this.number,
    this.sortIndex = 0,
    this.volumeTitle,
    this.releaseDate,
    this.locked = false,
    this.content,
  });

  final String sourceId;
  final String remoteId;
  final String title;

  /// 章节页地址；内容解析所需。
  final String? url;

  /// 章节号，支持 4.5 / 4.a 这类写法；无法识别时为 null。
  final double? number;

  /// 来源顺序（章节号缺失时仍能稳定排序）。
  final int sortIndex;

  final String? volumeTitle;
  final DateTime? releaseDate;

  /// 付费 / 锁定章节：只标注，不绕过、不缓存、不导出。
  final bool locked;

  /// 内容解析结果（未解析时为 null）。
  final ChapterContent? content;

  Chapter copyWith({ChapterContent? content}) => Chapter(
    sourceId: sourceId,
    remoteId: remoteId,
    title: title,
    url: url,
    number: number,
    sortIndex: sortIndex,
    volumeTitle: volumeTitle,
    releaseDate: releaseDate,
    locked: locked,
    content: content ?? this.content,
  );

  /// 从章节标题里尽力解析章节号（对齐 Mihon 的章节号识别的简化版）。
  ///
  /// 支持 `第12话`、`第 12.5 章`、`Ch.4`、`4.a`、`Vol.1 Ch.2` 等常见写法，
  /// 取标题中第一个数字（可带小数）作为章节号；解析不到返回 null。
  static double? parseNumber(String title) {
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(title);
    if (match == null) return null;
    return double.tryParse(match.group(1)!);
  }
}
