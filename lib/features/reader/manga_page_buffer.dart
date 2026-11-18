import 'dart:typed_data';

import '../../core/source/http_client.dart';
import '../../core/source/mihon_image_bridge.dart';

/// Reader-session buffer. Keep the earliest upcoming pages, never evict them
/// to make room for speculative later pages. Nothing is written to disk.
class MangaPageBuffer {
  MangaPageBuffer({this.capacity = 48 * 1024 * 1024});

  final int capacity;
  final _pages = <(String, String), Uint8List>{};
  SourceHttpClient? _client;
  int _bytes = 0;

  void _use(SourceHttpClient client) {
    if (identical(client, _client)) return;
    _pages.clear();
    _bytes = 0;
    _client = client;
  }

  Uint8List? get(SourceHttpClient client, String sourceId, String url) =>
      identical(_client, client) ? _pages[(sourceId, url)] : null;

  void retain(Set<(String, String)> keys) => _pages.removeWhere((key, bytes) {
    if (keys.contains(key)) return false;
    _bytes -= bytes.length;
    return true;
  });

  Future<bool> preload(
    SourceHttpClient client,
    String sourceId,
    String url,
    SourceRequestCancellation owner,
  ) async {
    if (owner.cancelled) return false;
    _use(client);
    final key = (sourceId, url);
    if (_pages.containsKey(key)) return true;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      return true;
    }
    final remaining = capacity - _bytes;
    if (remaining <= 0) return false;
    final data = await owner.run(() async {
      final native = await MihonImageBridge.tryLoadBytes(
        url,
        maxBytes: remaining,
      );
      if (owner.cancelled || native != null) return native;
      final result = await client.send(
        SourceRequest(
          url: url,
          responseBytes: true,
          maxResponseBytes: remaining,
          cancellation: owner,
        ),
        sourceId: sourceId,
      );
      return result.isSuccess ? result.bodyBytes : null;
    });
    if (owner.cancelled || !identical(client, _client)) return false;
    if (data == null || data.isEmpty) return true;
    if (data.length > capacity - _bytes) return false;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    _pages[key] = bytes;
    _bytes += bytes.length;
    return true;
  }
}
