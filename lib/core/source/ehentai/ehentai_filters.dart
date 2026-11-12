import 'dart:convert';

import 'ehentai_parsers.dart';

/// Android E-Hentai 1.6.36 `EhentaiFilters.kt` in the Mihon filter wire shape
/// (`MihonFilters.describe`): `{index, name, type, state, values}`.

const ehentaiBrowseModes = [
  '站内搜索',
  '我的收藏夹',
  '我的关注标签',
  '排行榜 · 昨日',
  '排行榜 · 本月',
  '排行榜 · 本年度',
  '排行榜 · 全部时间',
];
const ehentaiCategories = [
  '全部', 'Doujinshi', 'Manga', 'Artist CG', 'Game CG', 'Western', 'Non-H',
  'Image Set', 'Cosplay', 'Asian Porn', 'Misc',
];
const ehentaiRatings = ['不限', '2 星', '3 星', '4 星', '5 星'];
const ehentaiLanguages = [
  '不限', 'English', '中文', '日本語', '한국어', 'Français', 'Deutsch',
  'Español', 'Other',
];
const ehentaiFavoriteSorts = ['收藏时间 (Saved)', '发布日期 (Published)'];

abstract final class EhentaiFilterNames {
  static const browseHeader = '浏览 (Browse)';
  static const browseMode = '浏览来源 (Browse source)';
  static const watchedInclude = '关注标签 (Watched tags, any)';
  static const watchedExclude = '排除关注标签 (Hidden tags)';
  static const favoriteCategory = '收藏夹分类 (Favorite category)';
  static const favoriteKeyword = '收藏夹内标签/关键词 (Favorite tag / keyword)';
  static const favoriteSort = '收藏排序 (Favorite order)';
  static const seekDate = '跳转日期 (YYYY-MM-DD)';
  static const categoryHeader = '分类 (Category)';
  static const category = '分类 (Category)';
  static const searchHeader = '搜索选项 (Search options)';
  static const rating = '最低评分 (Minimum rating)';
  static const language = '语言 (Language)';
  static const pageHeader = '页数范围 (Page count)';
  static const pagesFrom = '页数下限 (Pages from)';
  static const pagesTo = '页数上限 (Pages to)';
  static const advancedHeader = '高级 (Advanced)';
  static const expunged = '包含已删除画廊 (Browse expunged)';
  static const torrent = '要求有种子 (Require torrent)';
  static const disableLanguage = '忽略语言标签筛选 (Ignore language tags)';
  static const disableUploader = '忽略上传者筛选 (Ignore uploader)';
  static const disableTags = '忽略标签筛选 (Ignore tags)';
}

List<String> defaultEhentaiFavoriteNames() => [
  for (var index = 0; index < 10; index++) '收藏夹 ${index + 1}',
];

/// Android `ehentaiFilterList`: 22 rows (21 filters + Browse header), same
/// order, names and values as the 1.6.36 FilterList.
List<Map<String, Object?>> ehentaiFilterRows([List<String>? favoriteNames]) {
  final favorites = favoriteNames ?? defaultEhentaiFavoriteNames();
  Map<String, Object?> header(String name) =>
      {'name': name, 'type': 'header', 'state': null, 'values': null};
  Map<String, Object?> select(String name, List<String> values) =>
      {'name': name, 'type': 'select', 'state': 0, 'values': [...values]};
  Map<String, Object?> text(String name) =>
      {'name': name, 'type': 'text', 'state': '', 'values': null};
  Map<String, Object?> check(String name) =>
      {'name': name, 'type': 'check', 'state': false, 'values': null};
  final rows = [
    header(EhentaiFilterNames.browseHeader),
    select(EhentaiFilterNames.browseMode, ehentaiBrowseModes),
    // Historical positions are kept for saved filter compatibility.
    text(EhentaiFilterNames.watchedInclude),
    text(EhentaiFilterNames.watchedExclude),
    select(EhentaiFilterNames.favoriteCategory, favorites),
    text(EhentaiFilterNames.favoriteKeyword),
    select(EhentaiFilterNames.favoriteSort, ehentaiFavoriteSorts),
    text(EhentaiFilterNames.seekDate),
    header(EhentaiFilterNames.categoryHeader),
    select(EhentaiFilterNames.category, ehentaiCategories),
    header(EhentaiFilterNames.searchHeader),
    select(EhentaiFilterNames.rating, ehentaiRatings),
    select(EhentaiFilterNames.language, ehentaiLanguages),
    header(EhentaiFilterNames.pageHeader),
    text(EhentaiFilterNames.pagesFrom),
    text(EhentaiFilterNames.pagesTo),
    header(EhentaiFilterNames.advancedHeader),
    check(EhentaiFilterNames.expunged),
    check(EhentaiFilterNames.torrent),
    check(EhentaiFilterNames.disableLanguage),
    check(EhentaiFilterNames.disableUploader),
    check(EhentaiFilterNames.disableTags),
  ];
  return [
    for (var index = 0; index < rows.length; index++)
      {'index': index, ...rows[index]},
  ];
}

/// Typed view over a filter row list (by name and type, not position).
class EhentaiFilterState {
  EhentaiFilterState(List<Map<String, Object?>> rows) : _rows = rows;

  /// Android `filters.ifEmpty { getFilterList() }`.
  factory EhentaiFilterState.of(List<Map<String, Object?>>? rows) =>
      EhentaiFilterState(
        rows == null || rows.isEmpty ? ehentaiFilterRows() : rows,
      );

  final List<Map<String, Object?>> _rows;

  Object? _state(String name, String type) {
    for (final row in _rows) {
      if (row['name'] == name && row['type'] == type) return row['state'];
    }
    return null;
  }

  int _select(String name) {
    final value = _state(name, 'select');
    return value is num ? value.toInt() : 0;
  }

  String _text(String name) {
    final value = _state(name, 'text');
    return value is String ? value : '';
  }

  bool _check(String name) => _state(name, 'check') == true;

  int get browseMode => _select(EhentaiFilterNames.browseMode);
  String get watchedInclude => _text(EhentaiFilterNames.watchedInclude);
  String get watchedExclude => _text(EhentaiFilterNames.watchedExclude);
  int get favoriteCategory => _select(EhentaiFilterNames.favoriteCategory);
  String get favoriteKeyword => _text(EhentaiFilterNames.favoriteKeyword);
  int get favoriteSort => _select(EhentaiFilterNames.favoriteSort);
  String get seekDate => _text(EhentaiFilterNames.seekDate);
  int get category => _select(EhentaiFilterNames.category);
  int get rating => _select(EhentaiFilterNames.rating);
  int get language => _select(EhentaiFilterNames.language);
  String get pagesFrom => _text(EhentaiFilterNames.pagesFrom);
  String get pagesTo => _text(EhentaiFilterNames.pagesTo);
  bool get expunged => _check(EhentaiFilterNames.expunged);
  bool get torrent => _check(EhentaiFilterNames.torrent);
  bool get disableLanguage => _check(EhentaiFilterNames.disableLanguage);
  bool get disableUploader => _check(EhentaiFilterNames.disableUploader);
  bool get disableTags => _check(EhentaiFilterNames.disableTags);

  /// Android `FilterList.hasNoActiveFilters`.
  bool get hasNoActiveFilters {
    final mode = browseMode;
    return mode == 0 &&
        (mode != 2 || watchedInclude.trim().isEmpty) &&
        (mode != 2 || watchedExclude.trim().isEmpty) &&
        (mode != 1 || favoriteCategory == 0) &&
        (mode != 1 || favoriteKeyword.trim().isEmpty) &&
        (mode != 1 || favoriteSort == 0) &&
        seekDate.trim().isEmpty &&
        category == 0 &&
        rating == 0 &&
        language == 0 &&
        pagesFrom.trim().isEmpty &&
        pagesTo.trim().isEmpty &&
        !expunged &&
        !torrent &&
        !disableLanguage &&
        !disableUploader &&
        !disableTags;
  }
}

/// `f_cats` bits in [ehentaiCategories] order (index 0 = All).
const _categoryBits = [0, 2, 4, 8, 16, 512, 256, 32, 64, 128, 1];
const _categoryAll = 1023;
const _ratingValues = [0, 2, 3, 4, 5];
const _languageKeywords = <String?>[
  null,
  'language:english',
  'language:chinese',
  'language:japanese',
  'language:korean',
  'language:french',
  'language:german',
  'language:spanish',
  'language:other',
];
const _toplists = [15, 13, 12, 11];

String _joinTerms(List<String> parts) =>
    parts.where((part) => part.trim().isNotEmpty).join(' ');

List<String> _exactTerms(String raw) => [
  ...{
    for (final part in raw.split(RegExp('[,\n\r]'))) ?ehentaiExactTagTerm(part),
  },
];

/// Android `buildSearchParams`, returned as the final URL string with OkHttp
/// query encoding and parameter order.
String buildEhentaiSearchUrl(
  String baseUrl,
  String query,
  EhentaiFilterState filters, {
  String? watchedTerms,
}) {
  final mode = filters.browseMode;
  // Ranklists are always served from E-Hentai, even on the ExHentai mirror.
  final requestBase = mode >= 3 && mode <= 6 ? 'https://e-hentai.org' : baseUrl;
  final base = Uri.parse(requestBase);
  var path = '/';
  final params = <(String, String)>[];
  if (mode == 1) {
    path = '/favorites.php';
    params.add(('favcat', '${filters.favoriteCategory}'));
  } else if (mode == 2 && watchedTerms == null) {
    path = '/watched';
  }
  var search = query.trim();

  if (mode == 2 && watchedTerms == null) {
    search = _joinTerms([search, _exactTerms(filters.watchedInclude).join(' ')]);
    search = _joinTerms([
      search,
      [for (final term in _exactTerms(filters.watchedExclude)) '-$term'].join(' '),
    ]);
  }
  final favoriteKeyword = filters.favoriteKeyword.trim();
  if (mode == 1 && favoriteKeyword.isNotEmpty) {
    search = _joinTerms([search, favoriteKeyword]);
  }
  final seek = filters.seekDate.trim();
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(seek)) params.add(('seek', seek));
  final bit = filters.category >= 0 && filters.category < _categoryBits.length
      ? _categoryBits[filters.category]
      : 0;
  if (bit != 0) params.add(('f_cats', '${_categoryAll ^ bit}'));
  final rating = filters.rating >= 0 && filters.rating < _ratingValues.length
      ? _ratingValues[filters.rating]
      : 0;
  if (rating > 0) params.add(('f_srdd', '$rating'));
  final language =
      filters.language >= 0 && filters.language < _languageKeywords.length
      ? _languageKeywords[filters.language]
      : null;
  if (language != null) search = _joinTerms([search, language]);
  final from = filters.pagesFrom.trim();
  if (from.isNotEmpty) params.add(('f_spf', from));
  final to = filters.pagesTo.trim();
  if (to.isNotEmpty) params.add(('f_spt', to));
  if (filters.expunged) params.add(('f_sh', 'on'));
  if (filters.torrent) params.add(('f_sto', 'on'));
  if (filters.disableLanguage) params.add(('f_sfl', 'on'));
  if (filters.disableUploader) params.add(('f_sfu', 'on'));
  if (filters.disableTags) params.add(('f_sft', 'on'));

  if (mode == 1) {
    params.add(('inline_set', filters.favoriteSort == 1 ? 'fs_p' : 'fs_f'));
  }
  if (mode >= 3 && mode <= 6) {
    path = '${path == '/' ? '' : path}/toplist.php';
    params.add(('tl', '${_toplists[mode - 3]}'));
  }
  if (mode == 2 && watchedTerms != null) {
    search = _joinTerms([search, watchedTerms]);
  }
  if (search.trim().isNotEmpty) params.add(('f_search', search));
  return ehentaiUrl(base, path, params);
}

String ehentaiUrl(Uri base, String path, List<(String, String)> params) {
  final buffer = StringBuffer('${base.scheme}://${base.host}');
  if (base.hasPort && base.port != 443 && base.port != 80) {
    buffer.write(':${base.port}');
  }
  buffer.write(path);
  if (params.isNotEmpty) {
    buffer.write('?');
    buffer.write(
      [
        for (final (name, value) in params)
          '${okhttpQueryEncode(name)}=${okhttpQueryEncode(value)}',
      ].join('&'),
    );
  }
  return buffer.toString();
}

/// OkHttp `QUERY_COMPONENT_ENCODE_SET`; `+` (plusIsSpace) and `%` are encoded too.
const _queryComponentEncodeSet = ' !"#\$&\'(),/:;<=>?@[]\\^`{|}~+%';

/// OkHttp `HttpUrl.Builder.addQueryParameter` encoding.
String okhttpQueryEncode(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    if (rune >= 0x21 &&
        rune <= 0x7E &&
        !_queryComponentEncodeSet.contains(char)) {
      buffer.write(char);
      continue;
    }
    for (final byte in utf8.encode(char)) {
      buffer.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return buffer.toString();
}


/// OkHttp `setQueryParameter`: drop every existing [name], append the new one.
String ehentaiSetQueryParameter(String url, String name, String value) {
  final hashIndex = url.indexOf('#');
  final fragment = hashIndex < 0 ? '' : url.substring(hashIndex);
  final withoutFragment = hashIndex < 0 ? url : url.substring(0, hashIndex);
  final queryIndex = withoutFragment.indexOf('?');
  final head = queryIndex < 0
      ? withoutFragment
      : withoutFragment.substring(0, queryIndex);
  final existing = queryIndex < 0
      ? const <String>[]
      : withoutFragment.substring(queryIndex + 1).split('&');
  final kept = [
    for (final pair in existing)
      if (pair.isNotEmpty &&
          Uri.decodeQueryComponent(pair.split('=').first) != name)
        pair,
  ];
  kept.add('${okhttpQueryEncode(name)}=${okhttpQueryEncode(value)}');
  return '$head?${kept.join('&')}$fragment';
}

/// OkHttp `addQueryParameter`.
String ehentaiAddQueryParameter(String url, String name, String value) {
  final pair = '${okhttpQueryEncode(name)}=${okhttpQueryEncode(value)}';
  final hashIndex = url.indexOf('#');
  final fragment = hashIndex < 0 ? '' : url.substring(hashIndex);
  final head = hashIndex < 0 ? url : url.substring(0, hashIndex);
  return head.contains('?') ? '$head&$pair$fragment' : '$head?$pair$fragment';
}
