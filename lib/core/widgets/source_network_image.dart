import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../source/http_client.dart';

/// Uses the same proxy, deadlines and TLS policy as source metadata requests.
/// Client identity is part of the cache key: a changed network configuration
/// must not reuse an in-flight request belonging to the previous client.
/// Public Bangumi covers use the image mirror before opening a potentially
/// blocked origin connection. [url] remains the cache identity (and portable
/// cover key); only the anonymous byte request is routed.
class SourceNetworkImage extends ImageProvider<SourceNetworkImage> {
  const SourceNetworkImage(
    this.url, {
    required this.http,
    this.sourceId = 'images',
    this.scale = 1,
  });

  final String url;
  final SourceHttpClient http;
  final String sourceId;
  final double scale;

  @override
  Future<SourceNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    SourceNetworkImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _load(decode), scale: scale);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    try {
      final requestUrl = _publicCoverRequestUrl(url);
      try {
        return await _fetchAndDecode(requestUrl, decode);
      } catch (_) {
        if (requestUrl == url) rethrow;
        return await _fetchAndDecode(url, decode);
      }
    } catch (_) {
      PaintingBinding.instance.imageCache.evict(this);
      rethrow;
    }
  }

  Future<ui.Codec> _fetchAndDecode(
    String requestUrl,
    ImageDecoderCallback decode,
  ) async {
    final data = await http.fetchBytes(requestUrl, sourceId: sourceId);
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is SourceNetworkImage &&
      other.url == url &&
      identical(other.http, http) &&
      other.sourceId == sourceId &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(url, identityHashCode(http), sourceId, scale);
}

final _publicBangumiPicturePath = RegExp(
  r'^/(?:r/\d+(?:x\d+)?/)?pic/(?:cover|crt)/',
);

String _publicCoverRequestUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.hasPort) {
    return url;
  }
  final publicPicture =
      uri.host == 'lain.bgm.tv' &&
      !uri.hasQuery &&
      _publicBangumiPicturePath.hasMatch(uri.path);
  final parts = uri.pathSegments;
  final publicApiPicture =
      uri.host == 'api.bgm.tv' &&
      parts.length == 4 &&
      parts[0] == 'v0' &&
      const {'subjects', 'characters', 'persons'}.contains(parts[1]) &&
      (int.tryParse(parts[2]) ?? 0) > 0 &&
      parts[3] == 'image' &&
      (!uri.hasQuery ||
          (uri.queryParametersAll.length == 1 &&
              uri.queryParametersAll['type']?.length == 1 &&
              const {
                'large',
                'common',
                'medium',
                'small',
                'grid',
              }.contains(uri.queryParameters['type'])));
  if (!publicPicture && !publicApiPicture) return url;
  return Uri.https('wsrv.nl', '/', {
    'url': '${uri.host}${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
    if (uri.path.toLowerCase().endsWith('.gif')) 'n': '-1',
  }).toString();
}
