import 'dart:async';
import 'dart:io';
import 'dart:math';

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
    final server = await (_server ??= _start());
    final path = '/$_token/$key';
    _loaders[path] = loader;
    return 'http://127.0.0.1:${server.port}$path';
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
