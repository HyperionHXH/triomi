import '../models/media_type.dart';

/// Metadata-only filters. A missing declaration is never a safe-content claim.
enum SourceContentRestriction {
  all('全部内容'),
  excludeNsfw('排除已标记 NSFW'),
  nsfwOnly('仅已标记 NSFW');

  const SourceContentRestriction(this.label);
  final String label;

  bool matches(bool? nsfw) => switch (this) {
    all => true,
    excludeNsfw => nsfw != true,
    nsfwOnly => nsfw == true,
  };
}

bool? sourceNsfwFlag(Object? value) => switch (value) {
  true || 1 => true,
  false || 0 => false,
  _ => null,
};

String sourceContentLabel(bool? nsfw) => switch (nsfw) {
  true => 'NSFW',
  false => '已声明非 NSFW',
  null => '内容分级未知',
};

String sourceLanguage(String value) => value.trim().toLowerCase().replaceAll('_', '-');
String sourceLanguageLabel(String value) => switch (value) {
  '' => '未知语言',
  'all' => '多语言 (all)',
  'zh' => '中文 (zh)',
  _ => value,
};

/// null means every language; zh selects the Chinese family; all is the
/// repository's explicit multilingual declaration, not a wildcard.
class SourceFilters {
  const SourceFilters({
    this.query = '',
    this.language,
    this.type,
    this.content = SourceContentRestriction.all,
  });

  final String query;
  final String? language;
  final MediaType? type;
  final SourceContentRestriction content;

  int get activeCount => (query.trim().isEmpty ? 0 : 1) +
      (language == null ? 0 : 1) + (type == null ? 0 : 1) +
      (content == SourceContentRestriction.all ? 0 : 1);

  bool matches({required Iterable<String> languages, required bool? nsfw,
    required MediaType? mediaType, required Iterable<String> searchText}) {
    if (type != null && type != mediaType) return false;
    if (!content.matches(nsfw)) return false;
    final selected = language == null ? null : sourceLanguage(language!);
    if (selected != null && !languages.any((raw) {
      final value = sourceLanguage(raw);
      return selected == 'zh'
          ? value == 'zh' || value.startsWith('zh-')
          : value == selected;
    })) {
      return false;
    }
    final needle = query.trim().toLowerCase();
    return needle.isEmpty || searchText.any((value) => value.toLowerCase().contains(needle));
  }

  SourceFilters copyWith({String? query, String? language, bool clearLanguage = false,
    MediaType? type, bool clearType = false, SourceContentRestriction? content}) => SourceFilters(
      query: query ?? this.query,
      language: clearLanguage ? null : language ?? this.language,
      type: clearType ? null : type ?? this.type,
      content: content ?? this.content,
    );

  Map<String, Object?> toJson() => {
    'query': query, 'language': language, 'type': type?.name, 'content': content.name,
  };

  static SourceFilters fromJson(Object? raw, {String? defaultLanguage}) {
    if (raw is! Map) return SourceFilters(language: defaultLanguage);
    return SourceFilters(
      query: raw['query'] is String ? raw['query'] as String : '',
      language: raw['language'] is String ? sourceLanguage(raw['language'] as String) : null,
      type: MediaType.tryParse(raw['type']?.toString()),
      content: SourceContentRestriction.values.where((value) => value.name == raw['content']).firstOrNull ?? SourceContentRestriction.all,
    );
  }
}
