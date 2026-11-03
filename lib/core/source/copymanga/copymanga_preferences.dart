import '../../storage/preferences.dart';
import '../source_catalog.dart';

const copyMangaPreferencePrefix = 'sources.copymanga.';
const copyMangaUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/114.0';
const copyMangaApiDomains = <String, String>{
  'api.mangacopy.com': '国际服',
  'mapi.copy20.com': '大陆专线 1',
  'mapi.copy2000.site': '大陆专线 2',
  'api.2026copy.com': '大陆专线 3',
  'api.copy3000.com': '拷贝新站',
  'api.copy4000.com': '拷贝新站 2（默认）',
};
const copyMangaWebDomains = <String, String>{
  'www.mangacopy.com': '国际服',
  'www.copy20.com': '大陆专线',
  'www.2026copy.com': '大陆专线 2',
  'www.copy3000.com': '大陆专线 3',
  'www.copy4000.com': '大陆专线 4（默认）',
};

bool supportsCopyMangaSettings(String id, String? version) {
  final parsed = CatalogVersion.tryParse(version ?? '');
  return id == 'copymanga' &&
      parsed != null &&
      parsed.compareTo(const CatalogVersion(1, 1, 0)) >= 0;
}

/// Non-secret settings only. Accounts and tokens never enter Preferences.
class CopyMangaPreferences {
  CopyMangaPreferences(this.preferences);
  final Preferences preferences;

  static const choices = <String, Set<String>>{
    'platform': {'', ' ', '1', '2', '3', '4', '5'},
    'resolution': {'800', '1200', '1500'},
    'latestMode': {'updated', 'new'},
    'commentMode': {'separate', 'merge'},
    'languageConversion': {'off', 's2t', 't2s'},
    'qType': {'', 'name', 'author', 'local'},
    'rank': {'', 'day', 'week', 'month', 'total'},
    'audience': {'', 'male', 'female'},
    'region': {'', 'japan', 'korea', 'west', 'finish'},
    'freeType': {'', '1', '2'},
    'ordering': {'-datetime_updated', 'datetime_updated', '-popular', 'popular'},
  };
  static const defaults = <String, Object>{
    'apiDomain': 'api.copy4000.com',
    'webDomain': 'www.copy4000.com',
    'commentApiDomain': 'api.copy4000.com',
    'platform': '1',
    'resolution': '1500',
    'latestMode': 'updated',
    'userAgent': copyMangaUserAgent,
    'hideChapters': '',
    'showMangaComments': false,
    'showChapterComments': false,
    'reverseChapterComments': false,
    'commentMode': 'separate',
    'commentRegex': '',
    'languageConversion': 'off',
    'enableLogin': false,
    'qType': '',
    'rank': '',
    'audience': '',
    'region': '',
    'theme': '',
    'freeType': '',
    'ordering': '-datetime_updated',
    'collect': false,
  };
  static const filterKeys = {
    'qType', 'rank', 'audience', 'region', 'theme', 'freeType', 'ordering', 'collect',
  };

  Object value(String key) {
    final fallback = defaults[key];
    if (fallback == null) throw ArgumentError.value(key, 'key');
    final stored = preferences.get<Object?>('$copyMangaPreferencePrefix$key');
    if (stored == null || !_valid(key, stored)) return fallback;
    return stored;
  }

  String get apiDomain => value('apiDomain') as String;
  bool get enableLogin => value('enableLogin') as bool;

  Map<String, Object?> get requestOptions => {
    for (final key in defaults.keys)
      if (!filterKeys.contains(key) && key != 'enableLogin') key: value(key),
    'filters': {for (final key in filterKeys) key: value(key)},
    'userAgentMode': const {'desktop', 'mobile', 'app', 'none'}.contains(value('userAgent'))
        ? value('userAgent') : 'custom',
  };

  Future<void> set(String key, Object value) async {
    if (!defaults.containsKey(key) || !_valid(key, value)) {
      throw ArgumentError('无效的拷贝漫画设置：$key');
    }
    if (key == 'commentRegex') {
      for (final line in (value as String).split('\n')) {
        if (line.trim().isNotEmpty) RegExp(line.trim());
      }
    }
    await preferences.set('$copyMangaPreferencePrefix$key',
      key == 'userAgent' && value == 'reset' ? copyMangaUserAgent : value);
  }

  bool _valid(String key, Object value) {
    if (defaults[key] is bool) return value is bool;
    if (value is! String || value.contains('\u0000')) return false;
    if (key == 'apiDomain' || key == 'commentApiDomain') {
      return copyMangaApiDomains.containsKey(value);
    }
    if (key == 'webDomain') return copyMangaWebDomains.containsKey(value);
    if (choices[key] case final allowed?) return allowed.contains(value);
    if (key == 'userAgent') {
      return value.trim().isNotEmpty && !value.contains('\r') && !value.contains('\n');
    }
    return true;
  }
}
