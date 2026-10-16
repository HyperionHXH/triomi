import '../../core/router/app_router.dart';

/// 来源 → 账号入口路由（D95）。
///
/// 内置小说来源有专属账号页；其余来源（含 JS 规则源）落到来源管理页，
/// 那里按能力显示每个来源的「账号」入口。认证失败时 UI 用这个映射把
/// 用户送到正确的登录位置，而不是只抛一句「需要登录」。
String accountRouteFor(String sourceId) => switch (sourceId) {
  'light-novel-kingdom' => AppRoutes.lkAccount,
  'light-novel-shelf' => AppRoutes.lnsAccount,
  _ => AppRoutes.sources,
};
