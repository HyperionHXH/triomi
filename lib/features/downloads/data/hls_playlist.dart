import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';

/// 一个码率变体（主播放列表里的 `#EXT-X-STREAM-INF`）。
class HlsVariant {
  const HlsVariant({required this.uri, required this.bandwidth});

  final Uri uri;

  /// 声明的带宽（bps）；没写时为 0。
  final int bandwidth;
}

/// HLS 播放列表（M3U8）：只解析「离线下载」需要的部分。
///
/// 支持两种列表：
/// - 主列表（含 `#EXT-X-STREAM-INF`）→ 挑最高带宽变体再取一次；
/// - 媒体列表（`#EXTINF` + 分段地址）→ 分段顺序即合并顺序。
///
/// 明确**不支持**加密流（`#EXT-X-KEY` 且 METHOD 不是 NONE）：调用方要报错，
/// 而不是下回一堆解不开的密文（延续「不绕过付费/加密」的红线）。
class HlsPlaylist {
  const HlsPlaylist({
    required this.uri,
    this.variants = const <HlsVariant>[],
    this.segments = const <Uri>[],
    this.initSegment,
    this.encrypted = false,
  });

  /// 本列表自身的地址（相对分段地址按它补全）。
  final Uri uri;

  final List<HlsVariant> variants;
  final List<Uri> segments;

  /// `#EXT-X-MAP` 声明的初始化段（fMP4 必需，合并时要放在最前面）。
  final Uri? initSegment;

  final bool encrypted;

  bool get isMaster => variants.isNotEmpty;

  /// 是否 fMP4（fragmented MP4）：合并结果应以 `.mp4` 落盘。
  bool get isFragmentedMp4 => initSegment != null;

  /// 最高带宽的变体；都没声明带宽时取第一个。
  Uri? get bestVariant {
    if (variants.isEmpty) return null;
    return variants.reduce((a, b) => b.bandwidth > a.bandwidth ? b : a).uri;
  }

  /// 内容嗅探：真正的 m3u8 一定以 `#EXTM3U` 开头。
  static bool looksLikeHls(String body) =>
      body.trimLeft().startsWith('#EXTM3U');

  /// 解析播放列表；[base] 是本列表的地址（用于补全相对地址）。
  static HlsPlaylist parse(String body, Uri base, {String sourceId = ''}) {
    if (!looksLikeHls(body)) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '不是有效的 HLS 播放列表（缺少 #EXTM3U）',
      );
    }

    final variants = <HlsVariant>[];
    final segments = <Uri>[];
    Uri? initSegment;
    var encrypted = false;
    var nextIsVariant = false;
    var pendingBandwidth = 0;

    Uri resolve(String value) => base.resolve(value.trim());

    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (!line.startsWith('#')) {
        if (nextIsVariant) {
          variants.add(
            HlsVariant(uri: resolve(line), bandwidth: pendingBandwidth),
          );
          nextIsVariant = false;
        } else {
          segments.add(resolve(line));
        }
        continue;
      }
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        nextIsVariant = true;
        pendingBandwidth = _intAttribute(line, 'BANDWIDTH') ?? 0;
        continue;
      }
      if (line.startsWith('#EXT-X-MAP')) {
        final value = _stringAttribute(line, 'URI');
        if (value != null && value.isNotEmpty) initSegment = resolve(value);
        continue;
      }
      if (line.startsWith('#EXT-X-KEY')) {
        final method = _stringAttribute(line, 'METHOD')?.toUpperCase();
        if (method != null && method != 'NONE') encrypted = true;
      }
    }

    if (variants.isEmpty && segments.isEmpty) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: 'HLS 播放列表里没有分段（也无法识别为多码率列表）',
      );
    }
    return HlsPlaylist(
      uri: base,
      variants: variants,
      segments: segments,
      initSegment: initSegment,
      encrypted: encrypted,
    );
  }

  /// 取属性值：`BANDWIDTH=12345` 这类数字属性。
  static int? _intAttribute(String line, String name) {
    final value = _stringAttribute(line, name);
    return value == null ? null : int.tryParse(value);
  }

  /// 取属性值：`URI="init.mp4"` 这类（属性值可能带引号，也可能不带）。
  static String? _stringAttribute(String line, String name) {
    final match = RegExp(
      '\\b${RegExp.escape(name)}=("[^"]*"|[^,]*)',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return null;
    final value = match.group(1) ?? '';
    return value.startsWith('"') && value.endsWith('"')
        ? value.substring(1, value.length - 1)
        : value.trim();
  }
}
