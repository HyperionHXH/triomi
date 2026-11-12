import '../../storage/preferences.dart';
import '../../storage/secure_store.dart';
import 'ehentai_parsers.dart';

/// Android E-Hentai 1.6.36 `Constants` / `MirrorPreferences` / `EhentaiPreferences`.
const ehentaiDefaultBaseUrl = 'https://e-hentai.org';
const exhentaiBaseUrl = 'https://exhentai.org';
const ehentaiDomain = 'e-hentai.org';
const exhentaiDomain = 'exhentai.org';
const ehentaiDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// `MirrorPreferences(mirrors = E-Hentai, ExHentai)`; values are list indexes.
const ehentaiMirrors = <(String, String)>[
  ('E-Hentai', ehentaiDefaultBaseUrl),
  ('ExHentai', exhentaiBaseUrl),
];

abstract final class EhentaiPrefKeys {
  static const mirror = 'preferred_mirror';
  static const memberId = 'ipb_member_id';
  static const passHash = 'ipb_pass_hash';
  static const igneous = 'igneous';
  static const accountTagSet = 'account_tag_set';
  static const watchedIncludeTags = 'watched_include_tags';
  static const watchedExcludeTags = 'watched_exclude_tags';
  static const proxyUrl = 'proxy_url';
  static const userAgent = 'user_agent';
  static const imageQuality = 'image_quality';
  static const preResolveImages = 'pre_resolve_images';
  static const requestInterval = 'request_interval';
  static const favoriteNames = 'favorite_category_names';
  static const accountWatchedTags = 'account_watched_tags';
  static const accountHiddenTags = 'account_hidden_tags';
  static const accountTagSetEnabled = 'account_tag_set_enabled';
  static const accountTagSyncAt = 'account_tag_sync_at';

  static const loginCookies = [memberId, passHash, igneous];
}

const ehentaiQualityStandard = 'standard';
const ehentaiQualityOriginal = 'original';
const ehentaiRequestIntervals = ['0', '500', '1000', '2000'];

/// Non-secret settings live in [Preferences] under `sources.ehentai.`; the
/// three login cookies (and the legacy combined cookie) only in [SecureStore].
/// Values are read on every access, like Android, so changes apply at once.
class EhentaiPreferences {
  EhentaiPreferences(this.preferences, this.secureStore);

  final Preferences preferences;
  final SecureStore secureStore;

  static const preferencePrefix = 'sources.ehentai.';
  static String secureKey(String name) => 'ehentai.$name';

  /// Android `PREF_COOKIE`, retained only to migrate a combined cookie.
  static final legacyCookieKey = secureKey('cookie');

  String? _string(String key) {
    final value = preferences.get<Object?>('$preferencePrefix$key');
    return value?.toString();
  }

  // ------------------------------------------------------------ mirror

  int get mirrorIndex {
    final index = int.tryParse(_string(EhentaiPrefKeys.mirror) ?? '0') ?? 0;
    return index.clamp(0, ehentaiMirrors.length - 1);
  }

  String get baseUrl => ehentaiMirrors[mirrorIndex].$2;
  bool get isExhentai => Uri.parse(baseUrl).host == exhentaiDomain;

  // ------------------------------------------------------------ cookies

  bool get _hasAnyCookieField => EhentaiPrefKeys.loginCookies.any(
    (name) => secureStore.get(secureKey(name)) != null,
  );

  /// The raw text as entered (or migrated). Never logged.
  String rawCookieField(String name) =>
      secureStore.get(secureKey(name)) ??
      (_hasAnyCookieField
          ? null
          : parseEhentaiCombinedCookie(
              secureStore.get(legacyCookieKey) ?? '',
            )[name]) ??
      '';

  String? cookieValue(String name) =>
      normalizeEhentaiCookieField(name, rawCookieField(name));

  List<(String, String)> get loginCookies => [
    for (final name in EhentaiPrefKeys.loginCookies)
      if (cookieValue(name) case final value?) (name, value),
  ];

  bool get hasLoginCookie =>
      EhentaiPrefKeys.loginCookies.every((name) => cookieValue(name) != null);

  /// Android `migrateCombinedCookie`: split an old combined value once.
  Future<void> migrateCombinedCookie() async {
    if (_hasAnyCookieField) return;
    final values = parseEhentaiCombinedCookie(
      secureStore.get(legacyCookieKey) ?? '',
    );
    if (values.isEmpty) return;
    for (final name in EhentaiPrefKeys.loginCookies) {
      if (values[name] case final value?) {
        await secureStore.set(secureKey(name), value);
      }
    }
  }

  Future<void> setCookieField(String name, String raw) async {
    if (!EhentaiPrefKeys.loginCookies.contains(name)) {
      throw ArgumentError.value(name, 'name');
    }
    final text = raw.trim();
    if (text.isEmpty) {
      await secureStore.remove(secureKey(name));
    } else {
      await secureStore.set(secureKey(name), text);
    }
  }

  Future<void> clearLoginCookies() async {
    for (final name in EhentaiPrefKeys.loginCookies) {
      await secureStore.remove(secureKey(name));
    }
    await secureStore.remove(legacyCookieKey);
  }

  // ------------------------------------------------------------ settings

  String get userAgent {
    final value = _string(EhentaiPrefKeys.userAgent)?.trim() ?? '';
    return value.isEmpty ? ehentaiDefaultUserAgent : value;
  }

  String get imageQuality =>
      _string(EhentaiPrefKeys.imageQuality) == ehentaiQualityOriginal
      ? ehentaiQualityOriginal
      : ehentaiQualityStandard;

  bool get wantOriginal => imageQuality == ehentaiQualityOriginal;

  bool get preResolveImages =>
      preferences.get<Object?>(
        '$preferencePrefix${EhentaiPrefKeys.preResolveImages}',
      ) ==
      true;

  int get requestIntervalMs =>
      int.tryParse(_string(EhentaiPrefKeys.requestInterval) ?? '0') ?? 0;

  String get proxyUrl => _string(EhentaiPrefKeys.proxyUrl)?.trim() ?? '';

  List<String> get watchedIncludeTags =>
      parseEhentaiTagList(_string(EhentaiPrefKeys.watchedIncludeTags) ?? '');
  List<String> get watchedExcludeTags =>
      parseEhentaiTagList(_string(EhentaiPrefKeys.watchedExcludeTags) ?? '');
  List<String> get accountWatchedTags =>
      parseEhentaiTagList(_string(EhentaiPrefKeys.accountWatchedTags) ?? '');
  List<String> get accountHiddenTags =>
      parseEhentaiTagList(_string(EhentaiPrefKeys.accountHiddenTags) ?? '');

  bool get accountTagSetEnabled =>
      preferences.get<Object?>(
        '$preferencePrefix${EhentaiPrefKeys.accountTagSetEnabled}',
      ) !=
      false;

  int get accountTagSetNumber {
    final value = int.tryParse(_string(EhentaiPrefKeys.accountTagSet) ?? '');
    return value != null && value > 0 ? value : 1;
  }

  int get accountTagSyncAt =>
      int.tryParse(_string(EhentaiPrefKeys.accountTagSyncAt) ?? '') ?? 0;

  Future<void> _put(String key, Object? value) =>
      preferences.set('$preferencePrefix$key', value);

  Future<void> saveAccountTagSet(AccountTagSet tagSet, {DateTime? now}) async {
    final watched = {
      for (final tag in tagSet.tags)
        if (tag.watched) tag.name,
    };
    final hidden = {
      for (final tag in tagSet.tags)
        if (tag.hidden) tag.name,
    };
    await _put(EhentaiPrefKeys.accountWatchedTags, watched.join('\n'));
    await _put(EhentaiPrefKeys.accountHiddenTags, hidden.join('\n'));
    await _put(EhentaiPrefKeys.accountTagSetEnabled, tagSet.enabled);
    await _put(EhentaiPrefKeys.accountTagSet, '${tagSet.selectedNumber}');
    await _put(
      EhentaiPrefKeys.accountTagSyncAt,
      '${(now ?? DateTime.now()).millisecondsSinceEpoch}',
    );
  }

  /// Favorite category labels are learned from favorites.php after login.
  List<String> get favoriteCategoryNames {
    final saved = (_string(EhentaiPrefKeys.favoriteNames) ?? '').split('|');
    return [
      for (var index = 0; index < 10; index++)
        index < saved.length && saved[index].trim().isNotEmpty
            ? saved[index].trim()
            : '收藏夹 ${index + 1}',
    ];
  }

  Future<void> saveFavoriteCategoryNames(List<String> names) async {
    final cleaned = [
      for (final name in names)
        if (name.trim().isNotEmpty) name.trim(),
    ].take(10).toList();
    if (cleaned.length == 10) {
      await _put(EhentaiPrefKeys.favoriteNames, cleaned.join('|'));
    }
  }

  /// The only hosts that may receive the login cookies.
  bool isSiteHost(String host) =>
      host == ehentaiDomain ||
      host.endsWith('.$ehentaiDomain') ||
      host == exhentaiDomain ||
      host.endsWith('.$exhentaiDomain');

  /// Settings-screen writes with Android's accepted values. Throws
  /// [FormatException] for a value Android's preference would reject.
  Future<void> set(String key, Object value) async {
    if (EhentaiPrefKeys.loginCookies.contains(key)) {
      await setCookieField(key, '$value');
      return;
    }
    switch (key) {
      case EhentaiPrefKeys.mirror:
        final index = int.tryParse('$value');
        if (index == null || index < 0 || index >= ehentaiMirrors.length) {
          throw const FormatException('镜像选项无效');
        }
        await _put(key, '$index');
      case EhentaiPrefKeys.accountTagSet:
        final number = int.tryParse('$value'.trim());
        if (number == null || number < 1 || number > 999) {
          throw const FormatException('关注标签组编号必须是 1–999 的整数');
        }
        await _put(EhentaiPrefKeys.accountTagSyncAt, '0');
        await _put(key, '$number');
      case EhentaiPrefKeys.watchedIncludeTags ||
          EhentaiPrefKeys.watchedExcludeTags ||
          EhentaiPrefKeys.userAgent:
        await _put(key, '$value');
      case EhentaiPrefKeys.proxyUrl:
        final text = '$value'.trim();
        final parsed = parseEhentaiProxy(text);
        if (parsed.error != null) throw FormatException(parsed.error!);
        if (text.isNotEmpty && parsed.proxy == null) {
          throw const FormatException(
            '代理地址无效：请填写 http://主机:端口 或 https://主机:端口',
          );
        }
        await _put(key, text);
      case EhentaiPrefKeys.imageQuality:
        if (value != ehentaiQualityStandard && value != ehentaiQualityOriginal) {
          throw const FormatException('图片质量选项无效');
        }
        await _put(key, value);
      case EhentaiPrefKeys.preResolveImages:
        if (value is! bool) throw const FormatException('开关值无效');
        await _put(key, value);
      case EhentaiPrefKeys.requestInterval:
        if (!ehentaiRequestIntervals.contains('$value')) {
          throw const FormatException('请求间隔选项无效');
        }
        await _put(key, '$value');
      default:
        throw ArgumentError.value(key, 'key', '未知的 E-Hentai 设置');
    }
  }
}

/// Android's `parseProxyUrl` scheme rules. iOS Dart networking implements
/// HTTP CONNECT proxies only; SOCKS is reported instead of being ignored.
({String? proxy, String? error}) parseEhentaiProxy(String value) {
  if (value.trim().isEmpty) return (proxy: null, error: null);
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return (proxy: null, error: null);
  switch (uri.scheme.toLowerCase()) {
    case 'http' || 'https':
      break;
    case 'socks' || 'socks5':
      return (
        proxy: null,
        error: 'iOS 不支持 SOCKS 代理（socks:// / socks5://）。'
            '请改用 http:// 或 https:// 代理地址，或留空跟随应用代理。',
      );
    default:
      return (proxy: null, error: null);
  }
  if (uri.host.isEmpty || !uri.hasPort || uri.port < 1 || uri.port > 65535) {
    return (proxy: null, error: null);
  }
  // Android uses Proxy.Type.HTTP for both schemes: a plain CONNECT proxy.
  return (
    proxy: Uri(scheme: 'http', host: uri.host, port: uri.port).toString(),
    error: null,
  );
}

const _trailingCookiePunctuation = {
  '.', ',', ':', ';', '!', '?', '\u3002', '\uFF0E', '\uFF0C', '\uFF1B',
};

String _trimChars(String value, Set<String> chars) {
  var start = 0, end = value.length;
  while (start < end && chars.contains(value[start])) {
    start++;
  }
  while (end > start && chars.contains(value[end - 1])) {
    end--;
  }
  return value.substring(start, end);
}

bool _isWhitespace(String char) => char.trim().isEmpty;

/// Android `normalizeCookieValue`: drop quotes, trailing punctuation and
/// whitespace; reject anything that is not visible ASCII.
String? normalizeEhentaiCookieValue(String raw) {
  var value = _trimChars(raw.trim(), const {'"', "'"});
  var end = value.length;
  while (end > 0 &&
      (_isWhitespace(value[end - 1]) ||
          _trailingCookiePunctuation.contains(value[end - 1]))) {
    end--;
  }
  value = value.substring(0, end);
  if (value.isEmpty) return null;
  for (final code in value.codeUnits) {
    if (code < 0x21 || code > 0x7E) return null;
  }
  return value;
}

/// Android `normalizeFieldCookieValue`: accepts `value`, `name=value`,
/// `Cookie: a=b; name=value` and trailing punctuation.
String? normalizeEhentaiCookieField(String name, String raw) {
  var text = raw;
  if (text.startsWith('Cookie:')) text = text.substring(7);
  text = text.trim();
  String? named;
  for (final part in text.split(';')) {
    final item = part.trim();
    if (item.toLowerCase().startsWith('${name.toLowerCase()}=')) {
      named = item.substring(item.indexOf('=') + 1);
      break;
    }
  }
  final value = named ?? text;
  return normalizeEhentaiCookieValue(
    value.contains('=') ? value.substring(value.indexOf('=') + 1) : value,
  );
}

/// Android `parseCombinedCookie` (legacy single `cookie` preference).
Map<String, String> parseEhentaiCombinedCookie(String raw) {
  var text = raw;
  if (text.startsWith('Cookie:')) text = text.substring(7);
  final result = <String, String>{};
  for (final part in text.split(';')) {
    final item = part.trim();
    final index = item.indexOf('=');
    if (index < 0) continue;
    final name = item.substring(0, index).trim();
    if (!EhentaiPrefKeys.loginCookies.contains(name)) continue;
    final value = normalizeEhentaiCookieValue(item.substring(index + 1));
    if (value != null) result[name] = value;
  }
  return result;
}

/// Android `parseTagList`.
List<String> parseEhentaiTagList(String raw) => [
  ...{
    for (final part in raw.split(RegExp('[,\n\r]')))
      if (part.trim().isNotEmpty) part.trim(),
  },
];
