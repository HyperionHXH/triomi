/// 追踪服务（第三方元数据服务）的公共类型。
///
/// 本项目约定书架状态的规范取值：`want / doing / done / paused / dropped`
/// （见 `library_entries.status`），各服务的状态码在本文件做一一映射。
enum TrackingServiceKind {
  bangumi('bangumi', 'Bangumi'),
  anilist('anilist', 'AniList');

  const TrackingServiceKind(this.wire, this.label);

  /// 落库值（`track_binds.service`）。
  final String wire;
  final String label;

  static TrackingServiceKind? parse(String raw) {
    for (final kind in TrackingServiceKind.values) {
      if (kind.wire == raw) return kind;
    }
    return null;
  }

  /// 凭据存放键（Preferences）。token 属敏感信息，**不得写日志**。
  String get tokenKey => 'tracking.$wire.token';
}

/// 本地状态 → 远端状态的映射表。
///
/// 两个易错点，测试里有专门断言：
/// - Bangumi 的 `type` 是 **2=看过、3=在看**（不是 2=在看）；
/// - AniList 用枚举字符串而不是数字。
abstract final class TrackStatusMap {
  /// 本地规范取值。
  static const List<String> localStatuses = <String>[
    'want',
    'doing',
    'done',
    'paused',
    'dropped',
  ];

  /// 本地 → Bangumi 收藏 type（1 想看 / 2 看过 / 3 在看 / 4 搁置 / 5 抛弃）。
  static const Map<String, int> bangumiType = <String, int>{
    'want': 1,
    'done': 2,
    'doing': 3,
    'paused': 4,
    'dropped': 5,
  };

  /// Bangumi type → 本地。
  static const Map<int, String> bangumiLocal = <int, String>{
    1: 'want',
    2: 'done',
    3: 'doing',
    4: 'paused',
    5: 'dropped',
  };

  /// 本地 → AniList MediaListStatus。
  static const Map<String, String> anilistStatus = <String, String>{
    'want': 'PLANNING',
    'doing': 'CURRENT',
    'done': 'COMPLETED',
    'paused': 'PAUSED',
    'dropped': 'DROPPED',
  };

  /// AniList MediaListStatus → 本地（大小写不敏感）。
  static String anilistToLocal(String raw) {
    final upper = raw.toUpperCase();
    for (final entry in anilistStatus.entries) {
      if (entry.value.toUpperCase() == upper) return entry.key;
    }
    return 'doing';
  }

  /// 未知的本地状态按「在看」处理（不抛错，追踪不该阻塞阅读）。
  static int bangumiTypeOf(String status) => bangumiType[status] ?? 3;

  static String anilistStatusOf(String status) =>
      anilistStatus[status] ?? 'CURRENT';
}

/// 搜索到的远端条目候选（绑定 UI 用）。
class TrackCandidate {
  const TrackCandidate({
    required this.remoteTrackId,
    required this.title,
    this.originalTitle,
    this.coverUrl,
    this.totalEpisodes,
  });

  final String remoteTrackId;
  final String title;

  /// 原名（Bangumi 的 name / AniList 的 romaji）。
  final String? originalTitle;
  final String? coverUrl;
  final int? totalEpisodes;
}

/// 一次上报的结果（部分成功要能逐项说明，聚合操作的红线）。
class TrackSyncResult {
  const TrackSyncResult({required this.kind, required this.ok, this.message});

  final TrackingServiceKind kind;
  final bool ok;

  /// 失败原因（面向用户，简短）。
  final String? message;

  @override
  String toString() =>
      '${kind.label}:${ok ? 'ok' : '失败（${message ?? '未知原因'}）'}';
}
