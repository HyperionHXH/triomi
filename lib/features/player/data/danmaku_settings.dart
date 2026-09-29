import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/source/source_providers.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/storage/secure_store.dart';
import 'dandanplay_client.dart';

/// 弹幕显示与过滤设置（对齐 Kazumi 的弹幕设置项，逐项持久化）。
class DanmakuSettings {
  const DanmakuSettings({
    this.enabled = true,
    this.opacity = 0.9,
    this.fontScale = 1.0,
    this.speedScale = 1.0,
    this.showScroll = true,
    this.showTop = true,
    this.showBottom = true,
    this.blockedWords = const <String>[],
    this.blockedUsers = const <String>[],
  });

  final bool enabled;

  /// 不透明度（0.2~1.0）。
  final double opacity;

  /// 字号缩放（0.6~1.6）。
  final double fontScale;

  /// 速度倍率（0.5~2.0，越大滚动越快、停留越短）。
  final double speedScale;

  final bool showScroll;
  final bool showTop;
  final bool showBottom;

  /// 屏蔽词：弹幕文本包含任一即过滤。
  final List<String> blockedWords;

  /// 按用户 ID 屏蔽（弹弹play 的 p 字段第 4 段）。
  final List<String> blockedUsers;

  /// 滚动弹幕停留时长（基础 9 秒，除以速度倍率）。
  int get scrollDurationMs => (9000 / speedScale).round();

  /// 顶部/底部弹幕停留时长。
  int get staticDurationMs => (4200 / speedScale).round();

  DanmakuSettings copyWith({
    bool? enabled,
    double? opacity,
    double? fontScale,
    double? speedScale,
    bool? showScroll,
    bool? showTop,
    bool? showBottom,
    List<String>? blockedWords,
    List<String>? blockedUsers,
  }) => DanmakuSettings(
    enabled: enabled ?? this.enabled,
    opacity: opacity ?? this.opacity,
    fontScale: fontScale ?? this.fontScale,
    speedScale: speedScale ?? this.speedScale,
    showScroll: showScroll ?? this.showScroll,
    showTop: showTop ?? this.showTop,
    showBottom: showBottom ?? this.showBottom,
    blockedWords: blockedWords ?? this.blockedWords,
    blockedUsers: blockedUsers ?? this.blockedUsers,
  );

  /// 一条弹幕是否被设置过滤掉。
  bool filters(String text, {String? user}) {
    if (blockedWords.any(text.contains)) return true;
    if (user != null && user.isNotEmpty && blockedUsers.contains(user)) {
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------- 持久化

  static const String _enabledKey = 'danmaku.enabled';
  static const String _opacityKey = 'danmaku.opacity';
  static const String _fontScaleKey = 'danmaku.fontScale';
  static const String _speedScaleKey = 'danmaku.speedScale';
  static const String _showScrollKey = 'danmaku.showScroll';
  static const String _showTopKey = 'danmaku.showTop';
  static const String _showBottomKey = 'danmaku.showBottom';
  static const String _blockedWordsKey = 'danmaku.blockedWords';
  static const String _blockedUsersKey = 'danmaku.blockedUsers';

  static DanmakuSettings load(Preferences preferences) => DanmakuSettings(
    enabled: preferences.get<bool>(_enabledKey) ?? true,
    opacity: (preferences.get<double>(_opacityKey) ?? 0.9).clamp(0.2, 1.0),
    fontScale: (preferences.get<double>(_fontScaleKey) ?? 1.0).clamp(0.6, 1.6),
    speedScale: (preferences.get<double>(_speedScaleKey) ?? 1.0).clamp(
      0.5,
      2.0,
    ),
    showScroll: preferences.get<bool>(_showScrollKey) ?? true,
    showTop: preferences.get<bool>(_showTopKey) ?? true,
    showBottom: preferences.get<bool>(_showBottomKey) ?? true,
    blockedWords: _stringList(preferences.get<List<Object?>>(_blockedWordsKey)),
    blockedUsers: _stringList(preferences.get<List<Object?>>(_blockedUsersKey)),
  );

  Future<void> save(Preferences preferences) async {
    await preferences.set(_enabledKey, enabled);
    await preferences.set(_opacityKey, opacity);
    await preferences.set(_fontScaleKey, fontScale);
    await preferences.set(_speedScaleKey, speedScale);
    await preferences.set(_showScrollKey, showScroll);
    await preferences.set(_showTopKey, showTop);
    await preferences.set(_showBottomKey, showBottom);
    await preferences.set(_blockedWordsKey, blockedWords);
    await preferences.set(_blockedUsersKey, blockedUsers);
  }

  static List<String> _stringList(List<Object?>? raw) => <String>[
    for (final item in raw ?? const <Object?>[])
      if (item != null && item.toString().trim().isNotEmpty)
        item.toString().trim(),
  ];
}

/// 弹幕设置（跨页面共享的可变状态）。
class DanmakuSettingsController extends Notifier<DanmakuSettings> {
  @override
  DanmakuSettings build() =>
      DanmakuSettings.load(ref.watch(preferencesProvider));

  Future<void> update(DanmakuSettings next) async {
    state = next;
    await next.save(ref.read(preferencesProvider));
  }
}

final danmakuSettingsProvider =
    NotifierProvider<DanmakuSettingsController, DanmakuSettings>(
      DanmakuSettingsController.new,
    );

/// 弹弹play 凭据（AppId / AppSecret，用于弹幕匹配与发送；不落日志）。
class DandanplayCredentials {
  const DandanplayCredentials({
    this.appId = '',
    this.appSecret = '',
    this.token = '',
  });

  final String appId;
  final String appSecret;

  /// 发送弹幕需要用户 token（弹弹play 的账号授权码）。
  final String token;

  bool get isConfigured => appId.isNotEmpty && appSecret.isNotEmpty;

  bool get canSend => isConfigured && token.isNotEmpty;

  /// 应用自己的弹弹play 凭据（Triomi 注册的应用）。
  ///
  /// 用户没填自己的凭据时用它，这样**「拿弹幕」开箱可用**（与 Kazumi 的做法
  /// 一致：Kazumi 也是内置了自己注册的那对凭据）；**发弹幕仍然需要用户自己的
  /// 账号 token**。留空则维持旧行为（要求用户自填）。
  ///
  /// 可以在构建时注入，避免把值写进仓库：
  /// `--dart-define=TRIOMI_DANDANPLAY_APP_ID=xxx --dart-define=TRIOMI_DANDANPLAY_APP_SECRET=yyy`
  static const String builtInAppId = String.fromEnvironment(
    'TRIOMI_DANDANPLAY_APP_ID',
  );
  static const String builtInAppSecret = String.fromEnvironment(
    'TRIOMI_DANDANPLAY_APP_SECRET',
  );

  /// 内置凭据是否可用（未注入时 false，界面仍走「请先配置」的老路）。
  static bool get hasBuiltIn =>
      builtInAppId.isNotEmpty && builtInAppSecret.isNotEmpty;

  DandanplayCredentials copyWith({
    String? appId,
    String? appSecret,
    String? token,
  }) => DandanplayCredentials(
    appId: appId ?? this.appId,
    appSecret: appSecret ?? this.appSecret,
    token: token ?? this.token,
  );

  static const String appIdKey = 'danmaku.dandanplay.appId';
  static const String appSecretKey = 'danmaku.dandanplay.appSecret';
  static const String tokenKey = 'danmaku.dandanplay.token';

  /// 机密字段（appSecret / token）从安全存储读，Hive 里的旧值（迁移前
  /// 备份）作回退；appId 非机密，留在 Hive。
  ///
  /// 用户没填 AppId/AppSecret 时回退到应用内置的那对（[hasBuiltIn]）。
  static DandanplayCredentials load(
    Preferences preferences,
    SecureStore secureStore,
  ) {
    final userAppId = preferences.get<String>(appIdKey) ?? '';
    final userAppSecret =
        secureStore.get(appSecretKey) ??
        preferences.get<String>(appSecretKey) ??
        '';
    return DandanplayCredentials(
      appId: userAppId.isNotEmpty ? userAppId : builtInAppId,
      appSecret: userAppSecret.isNotEmpty ? userAppSecret : builtInAppSecret,
      token:
          secureStore.get(tokenKey) ?? preferences.get<String>(tokenKey) ?? '',
    );
  }

  Future<void> save(Preferences preferences, SecureStore secureStore) async {
    await preferences.set(appIdKey, appId);
    await secureStore.set(appSecretKey, appSecret);
    await secureStore.set(tokenKey, token);
  }
}

class DandanplayCredentialsController extends Notifier<DandanplayCredentials> {
  @override
  DandanplayCredentials build() => DandanplayCredentials.load(
    ref.watch(preferencesProvider),
    ref.watch(secureStoreProvider),
  );

  /// 保存凭据。**落盘的是用户填的原值，state 里放的是「生效值」**。
  ///
  /// 两者必须分开：用户把 AppId/AppSecret 清空时，落盘要留空（保持「用户没填」的语义），
  /// 但 state 必须退回内置凭据——否则弹幕设置页会显示「未配置」、`dandanplayClientProvider`
  /// 也真的拿不到内置值，**要重启 App 才恢复**（设备实测踩到的）。规则与
  /// [DandanplayCredentials.load] 保持一致。
  Future<void> update(DandanplayCredentials next) async {
    state = DandanplayCredentials(
      appId: next.appId.isNotEmpty
          ? next.appId
          : DandanplayCredentials.builtInAppId,
      appSecret: next.appSecret.isNotEmpty
          ? next.appSecret
          : DandanplayCredentials.builtInAppSecret,
      token: next.token,
    );
    await next.save(
      ref.read(preferencesProvider),
      ref.read(secureStoreProvider),
    );
  }

  /// 用账号密码登录弹弹play，成功后把 token 写回凭据并持久化。
  ///
  /// 失败抛 [SourceException]（由界面提示），token 保持原值。
  /// 密码**不落盘、不落日志**——只作为本次请求参数传给客户端，
  /// 持久化内容里只有 appId / appSecret / token。
  Future<String?> login(String userName, String password) async {
    // 不走 dandanplayClientProvider：本控制器属于 credentials provider，
    // 而 client provider watch 凭据，read 会构成循环依赖（见其文档）。
    final client = DandanplayClient(
      http: ref.read(sourceHttpClientProvider),
      appId: state.appId,
      appSecret: state.appSecret,
      baseUrl: dandanplayBaseUrl,
    );
    final token = await client.login(userName: userName, password: password);
    await update(state.copyWith(token: token));
    return token;
  }
}

final dandanplayCredentialsProvider =
    NotifierProvider<DandanplayCredentialsController, DandanplayCredentials>(
      DandanplayCredentialsController.new,
    );

/// 弹弹play 的服务地址；可被 `--dart-define=TRIOMI_DANDANPLAY_BASE` 覆盖
/// （模拟器没有外网时指向夹具服务，验证登录与发送全链路）。
const String dandanplayBaseUrl = String.fromEnvironment(
  'TRIOMI_DANDANPLAY_BASE',
  defaultValue: 'https://api.dandanplay.net',
);

/// 弹弹play 客户端（凭据变化时重建）。
///
/// 注意：凭据控制器**不能** read 本 provider——它自身就在 credentials
/// provider 里，而本 provider watch 凭据，会构成循环依赖
/// （Riverpod 3 的 debug assert 会直接抛 CircularDependencyError）。
/// 控制器里需要 client 时自行用 [dandanplayBaseUrl] 构造。
final dandanplayClientProvider = Provider<DandanplayClient>((ref) {
  final credentials = ref.watch(dandanplayCredentialsProvider);
  return DandanplayClient(
    http: ref.watch(sourceHttpClientProvider),
    appId: credentials.appId,
    appSecret: credentials.appSecret,
    baseUrl: dandanplayBaseUrl,
  );
});
