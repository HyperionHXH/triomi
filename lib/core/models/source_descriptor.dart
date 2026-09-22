import 'media_type.dart';

/// 来源能力。
///
/// 对齐 Mixn 的「能力接口」设计：来源按需实现、UI 按能力显隐功能，
/// 而不是把某个站点的功能写死进界面。
enum SourceCapability {
  discover('榜单'),
  search('搜索'),
  detail('详情'),
  content('正文'),
  account('账号'),
  remoteShelf('远端书架'),
  progressSync('进度同步'),
  unlock('付费解锁'),
  comment('评论'),
  reward('签到');

  const SourceCapability(this.label);

  final String label;
}

/// 来源描述信息（不依赖任何解析实现，可用于列表展示）。
class SourceDescriptor {
  const SourceDescriptor({
    required this.id,
    required this.name,
    required this.type,
    required this.kind,
    this.lang = 'zh',
    this.baseUrl,
    this.version,
    this.requireLogin = false,
    this.capabilities = const <SourceCapability>{},
  });

  /// 稳定本地标识（不是站点 ID）。
  final String id;
  final String name;
  final MediaType type;
  final SourceKind kind;
  final String lang;
  final String? baseUrl;
  final String? version;

  /// 是否需要登录（需要时 UI 要提示先到账号页登录，而不是直接报解析失败）。
  final bool requireLogin;

  final Set<SourceCapability> capabilities;

  bool supports(SourceCapability capability) =>
      capabilities.contains(capability);

  SourceDescriptor copyWith({
    SourceKind? kind,
    Set<SourceCapability>? capabilities,
    bool? requireLogin,
    String? version,
  }) => SourceDescriptor(
    id: id,
    name: name,
    type: type,
    kind: kind ?? this.kind,
    lang: lang,
    baseUrl: baseUrl,
    version: version ?? this.version,
    requireLogin: requireLogin ?? this.requireLogin,
    capabilities: capabilities ?? this.capabilities,
  );
}
