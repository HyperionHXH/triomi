import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'http_client.dart';

typedef MihonImageLoader = Future<Map<String, Object?>> Function();

/// The reader and downloader consume HTTP images. This loopback-only bridge
/// defers the native plugin request until a page is visible and streams the
/// host's cached file without passing full image bytes over MethodChannel.
abstract final class MihonImageBridge {
  static Future<HttpServer>? _server;
  static final _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  static final _loaders = <String, MihonImageLoader>{};
  static final _pending = <String, Future<Map<String, Object?>>>{};

  static Future<String> register(String key, MihonImageLoader loader) async {
    final Future<HttpServer> pending =
        _server ?? Zone.root.run<Future<HttpServer>>(_start);
    _server = pending;
    final server = await pending;
    final path = '/$_token/$key';
    _loaders[path] = loader;
    return 'http://127.0.0.1:${server.port}$path';
  }

  /// Downloads run in a cancellable operation zone. Loading registered images
  /// directly preserves that owner across the native/desktop host seam instead
  /// of losing it on the loopback HTTP server's unrelated request zone.
  static Future<List<int>?> tryLoadBytes(String value) async {
    final uri = Uri.tryParse(value);
    final server = _server;
    if (server == null ||
        uri == null ||
        uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    if (uri.port != (await server).port) return null;
    final loader = _loaders[uri.path];
    if (loader == null) return null;
    final cancellation = SourceRequestCancellation.current;
    if (cancellation?.cancelled == true) throw cancellation!.token.cancelError!;
    final result = await loader();
    if (cancellation?.cancelled == true) throw cancellation!.token.cancelError!;
    final path = result['filePath'];
    if (path is! String) throw StateError('Missing plugin image file');
    final bytes = await File(path).readAsBytes();
    if (cancellation?.cancelled == true) throw cancellation!.token.cancelError!;
    return bytes;
  }

  static Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_serve(request)));
    return server;
  }

  static Future<void> _serve(HttpRequest request) async {
    try {
      final loader = _loaders[request.uri.path];
      if (loader == null || !['GET', 'HEAD'].contains(request.method)) {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      final path = request.uri.path;
      final future = _pending.putIfAbsent(path, loader);
      Map<String, Object?> result;
      try {
        result = await future;
      } finally {
        if (identical(_pending[path], future)) {
          unawaited(_pending.remove(path));
        }
      }
      final filePath = result['filePath'];
      if (filePath is! String) throw StateError('Missing plugin image file');
      final file = File(filePath);
      request.response.headers.contentType = ContentType.parse(
        '${result['mime'] ?? 'image/jpeg'}',
      );
      request.response.contentLength = await file.length();
      if (request.method == 'GET') {
        await request.response.addStream(file.openRead());
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.badGateway;
    } finally {
      try {
        await request.response.close();
      } on IOException {
        // A disposed image widget may have closed its connection already.
      }
    }
  }
}
