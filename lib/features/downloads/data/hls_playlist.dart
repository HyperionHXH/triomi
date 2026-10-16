import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';

class HlsVariant {
  const HlsVariant({required this.uri, required this.bandwidth});
  final Uri uri;
  final int bandwidth;
}

/// One independently cached resource; byte ranges become complete local files.
class HlsResource {
  const HlsResource(this.uri, {this.offset, this.length});
  final Uri uri;
  final int? offset, length;
  String get identity => '$uri|${offset ?? ''}|${length ?? ''}';
}

class HlsPlaylist {
  const HlsPlaylist({
    required this.uri,
    this.variants = const [],
    this.segments = const [],
    this.initSegment,
    this.encrypted = false,
    this.resources = const [],
    this.localLines = const [],
    this.complete = false,
    this.externalRenditions = false,
  });
  final Uri uri;
  final List<HlsVariant> variants;
  final List<Uri> segments;
  final Uri? initSegment;
  final bool encrypted, complete, externalRenditions;
  final List<HlsResource> resources;

  /// Tags plus resource placeholders, never network addresses in offline output.
  final List<String> localLines;
  bool get isMaster => variants.isNotEmpty;
  bool get isFragmentedMp4 => initSegment != null;
  Uri? get bestVariant => variants.isEmpty
      ? null
      : variants.reduce((a, b) => b.bandwidth > a.bandwidth ? b : a).uri;
  static bool looksLikeHls(String body) =>
      body.trimLeft().startsWith('#EXTM3U');
  String offline(Map<String, String> files) => localLines
      .map((line) {
        final marker = RegExp(r'@RESOURCE:(\d+)@');
        return line.replaceAllMapped(
          marker,
          (m) => files[resources[int.parse(m[1]!)].identity]!,
        );
      })
      .join('\n');

  static HlsPlaylist parse(String body, Uri base, {String sourceId = ''}) {
    Never fail(String text) => throw SourceException(
      sourceId: sourceId,
      type: SourceErrorType.parse,
      message: text,
    );
    if (!looksLikeHls(body)) fail('不是有效的 HLS 播放列表（缺少 #EXTM3U）');
    final variants = <HlsVariant>[];
    final segments = <Uri>[];
    final resources = <HlsResource>[];
    final local = <String>[];
    Uri? init;
    var encrypted = false,
        nextVariant = false,
        complete = false,
        external = false;
    var bandwidth = 0;
    int? rangeLength, rangeOffset;
    Uri? previousRangeUri;
    var previousRangeEnd = 0;
    Uri resolve(String value) {
      final uri = base.resolve(value.trim());
      if (!['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          (base.scheme == 'https' && uri.scheme != 'https')) {
        fail('HLS 地址无效或发生 HTTPS 降级');
      }
      return uri;
    }

    HlsResource range(Uri uri, String value, {bool map = false}) {
      final parts = value.split('@');
      final length = int.tryParse(parts.first);
      final explicit = parts.length == 2 ? int.tryParse(parts.last) : null;
      if (length == null ||
          length <= 0 ||
          parts.length > 2 ||
          (parts.length == 2 && (explicit == null || explicit < 0))) {
        fail('HLS BYTERANGE 无效');
      }
      if (explicit == null && (map || previousRangeUri != uri)) {
        fail('HLS 隐式 BYTERANGE 缺少同文件前段');
      }
      final offset = explicit ?? previousRangeEnd;
      if (!map) {
        previousRangeUri = uri;
        previousRangeEnd = offset + length;
      }
      return HlsResource(uri, offset: offset, length: length);
    }

    String add(HlsResource resource) {
      final index = resources.length;
      resources.add(resource);
      return '@RESOURCE:$index@';
    }

    for (final raw in body.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (!line.startsWith('#')) {
        final uri = resolve(line);
        if (nextVariant) {
          variants.add(HlsVariant(uri: uri, bandwidth: bandwidth));
          nextVariant = false;
        } else {
          segments.add(uri);
          final resource = rangeLength == null
              ? HlsResource(uri)
              : range(
                  uri,
                  '$rangeLength${rangeOffset == null ? '' : '@$rangeOffset'}',
                );
          if (rangeLength == null) {
            previousRangeUri = null;
            previousRangeEnd = 0;
          }
          rangeLength = null;
          rangeOffset = null;
          local.add(add(resource));
        }
      } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
        nextVariant = true;
        bandwidth = int.tryParse(_attribute(line, 'BANDWIDTH') ?? '') ?? 0;
      } else if (line.startsWith('#EXT-X-MEDIA:')) {
        external |= _attribute(line, 'URI') != null;
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final address = _attribute(line, 'URI');
        if (address == null || address.isEmpty) fail('HLS 初始化段没有 URI');
        init = resolve(address);
        final bytes = _attribute(line, 'BYTERANGE');
        final resource = bytes == null
            ? HlsResource(init)
            : range(init, bytes, map: true);
        local.add('#EXT-X-MAP:URI="${add(resource)}"');
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        final value = line.substring('#EXT-X-BYTERANGE:'.length).split('@');
        rangeLength = int.tryParse(value.first);
        rangeOffset = value.length == 2 ? int.tryParse(value.last) : null;
        if (rangeLength == null ||
            rangeLength <= 0 ||
            value.length > 2 ||
            (value.length == 2 && (rangeOffset == null || rangeOffset < 0))) {
          fail('HLS BYTERANGE 无效');
        }
      } else if (line.startsWith('#EXT-X-KEY:') ||
          line.startsWith('#EXT-X-SESSION-KEY:')) {
        encrypted |= (_attribute(line, 'METHOD') ?? '').toUpperCase() != 'NONE';
      } else {
        if (line == '#EXT-X-ENDLIST') complete = true;
        // URI-bearing extension tags are not silently copied into offline files.
        if (_attribute(line, 'URI') != null) fail('HLS 包含尚不支持的外部资源标签');
        local.add(line);
      }
    }
    if (variants.isEmpty && segments.isEmpty) {
      fail('HLS 播放列表里没有分段（也无法识别为多码率列表）');
    }
    if (nextVariant || rangeLength != null) fail('HLS 播放列表结尾不完整');
    return HlsPlaylist(
      uri: base,
      variants: variants,
      segments: segments,
      initSegment: init,
      encrypted: encrypted,
      complete: complete,
      externalRenditions: external,
      resources: resources,
      localLines: local,
    );
  }

  static String? _attribute(String line, String name) {
    final match = RegExp(
      '\\b${RegExp.escape(name)}=("[^"]*"|[^,]*)',
      caseSensitive: false,
    ).firstMatch(line);
    final value = match?[1];
    if (value == null) return null;
    return value.startsWith('"') && value.endsWith('"')
        ? value.substring(1, value.length - 1)
        : value.trim();
  }
}
