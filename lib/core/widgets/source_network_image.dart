import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../source/bangumi_route_policy.dart';
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
      final routes = http is BangumiImageRoutingClient
          ? (http as BangumiImageRoutingClient).bangumiRoutes
          : const BangumiRoutePolicy();
      final requestUrl = routes.coverRequestUrl(url);
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
