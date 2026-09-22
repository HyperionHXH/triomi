/// 三种内容形态。全应用共用一套模型（见 PROJECT_SPEC 4.2）。
enum MediaType {
  anime('番剧'),
  manga('漫画'),
  novel('小说');

  const MediaType(this.label);

  /// 界面展示名。
  final String label;

  static MediaType? tryParse(String? value) {
    if (value == null) return null;
    for (final type in MediaType.values) {
      if (type.name == value) return type;
    }
    return null;
  }
}

/// 来源类型：随包编译的内置适配器，或运行时加载的 JS 扩展源。
///
/// 内置适配器用于需要登录态 / 付费 / 私有协议的站点（LK、LNS），
/// JS 扩展源用于普通公开站点（见 PROJECT_SPEC 4.3 双轨来源体系）。
enum SourceKind {
  builtin('内置'),
  plugin('扩展');

  const SourceKind(this.label);

  final String label;
}

/// 来源错误分类（沿用 Mixn 设计）：聚合操作允许部分成功，
/// 每个失败都必须能说明「是哪个源、哪一类错误」。
enum SourceErrorType {
  auth('需要登录'),
  rateLimited('请求过于频繁'),
  timeout('请求超时'),
  parse('解析失败'),
  permission('无访问权限'),
  notFound('内容不存在'),
  network('网络异常');

  const SourceErrorType(this.label);

  final String label;
}
