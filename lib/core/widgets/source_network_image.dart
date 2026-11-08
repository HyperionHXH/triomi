import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../source/bangumi_route_policy.dart';
import '../source/http_client.dart';
import '../storage/cover_store.dart';

/// Uses the same proxy, deadlines and TLS policy as source metadata requests.
/// Client identity is part of the cache key: a changed network configuration
/// must not reuse an in-flight request belonging to the previous client.
/// Public Bangumi covers use the image mirror before opening a potentially
/// blocked origin connection. [url] remains the cache identity (and portable
/// cover key); only the anonymous byte request is routed.
/// Anonymous public covers reuse [CoverStore] after the bounded Flutter image
/// cache evicts them. Other image URLs remain scoped to this HTTP client.
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
      CoverStore? store;
      if (const BangumiRoutePolicy().isPublicCover(url)) {
        try {
          store = await CoverStore.open();
        } catch (_) {
          // Unsupported/unavailable local storage must not prevent rendering.
        }
      }
      Uint8List? cached;
      if (store != null) {
        try {
          cached = await store.read(url);
        } catch (_) {
          // A cache read failure is not a failed network request.
        }
      }
      if (cached != null) {
        try {
          return await decode(await ui.ImmutableBuffer.fromUint8List(cached));
        } catch (_) {
          try {
            await store!.removeIfMatches(url, cached);
          } catch (_) {
            // Read-only or busy storage still permits a fresh network image.
          }
        }
      }
      final routes = http is BangumiImageRoutingClient
          ? (http as BangumiImageRoutingClient).bangumiRoutes
          : const BangumiRoutePolicy();
      final requestUrl = routes.coverRequestUrl(url);
      try {
        return await _fetchAndDecode(requestUrl, decode, store);
      } catch (_) {
        if (requestUrl == url) rethrow;
        return await _fetchAndDecode(url, decode, store);
      }
    } catch (_) {
      PaintingBinding.instance.imageCache.evict(this);
      rethrow;
    }
  }

  Future<ui.Codec> _fetchAndDecode(
    String requestUrl,
    ImageDecoderCallback decode,
    CoverStore? store,
  ) async {
    final data = await http.fetchBytes(requestUrl, sourceId: sourceId);
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    if (store != null) {
      try {
        // Persist only successfully decoded bytes, under the portable origin
        // URL rather than the current mirror/proxy route.
        await store.putIfMissing(url, bytes);
      } catch (_) {
        // Persistence is best effort; the decoded image is already usable.
      }
    }
    return codec;
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
