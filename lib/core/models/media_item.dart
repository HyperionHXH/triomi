import 'media_type.dart';

/// 作品（一部番剧 / 漫画 / 小说）在应用内的统一表示。
///
/// 来源层负责把各站的数据映射成它；UI 只认这个模型。
class MediaItem {
  const MediaItem({
    required this.sourceId,
    required this.remoteId,
    required this.type,
    required this.title,
    this.url,
    this.coverUrl,
    this.author,
    this.description,
    this.tags = const <String>[],
    this.rating,
    this.status,
  });

  /// 来源标识。与 [remoteId] 一起构成业务键。
  final String sourceId;

  /// 该作品在来源内部的标识。
  final String remoteId;

  final MediaType type;
  final String title;

  /// 详情页地址（相对地址已在解析时补全为绝对地址）。
  final String? url;
  final String? coverUrl;
  final String? author;
  final String? description;
  final List<String> tags;
  final double? rating;

  /// 连载中 / 已完结 / 未知（原样保留来源文案）。
  final String? status;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'remoteId': remoteId,
    'type': type.name,
    'title': title,
    'url': url,
    'coverUrl': coverUrl,
    'author': author,
    'description': description,
    'tags': tags,
    'rating': rating,
    'status': status,
  };

  static MediaItem fromJson(
    Map<String, Object?> json, {
    required String sourceId,
    MediaType? fallbackType,
  }) {
    return MediaItem(
      sourceId: sourceId,
      remoteId: json['remoteId']?.toString() ?? '',
      type:
          MediaType.tryParse(json['type']?.toString()) ??
          fallbackType ??
          MediaType.manga,
      title: json['title']?.toString() ?? '',
      url: json['url']?.toString(),
      coverUrl: json['coverUrl']?.toString(),
      author: json['author']?.toString(),
      description: json['description']?.toString(),
      tags: <String>[
        for (final tag in (json['tags'] as List<Object?>? ?? const <Object?>[]))
          if (tag != null && tag.toString().trim().isNotEmpty) tag.toString(),
      ],
      rating: double.tryParse(json['rating']?.toString() ?? ''),
      status: json['status']?.toString(),
    );
  }

  MediaItem copyWith({String? coverUrl, String? description}) => MediaItem(
    sourceId: sourceId,
    remoteId: remoteId,
    type: type,
    title: title,
    url: url,
    coverUrl: coverUrl ?? this.coverUrl,
    author: author,
    description: description ?? this.description,
    tags: tags,
    rating: rating,
    status: status,
  );
}
