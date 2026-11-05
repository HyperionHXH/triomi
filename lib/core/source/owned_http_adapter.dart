import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Dart HttpClientRequest.abort cannot destroy a response after its headers.
/// A cancellable fetch therefore owns its transport, including proxy/ECH route
/// resources. Closing it cannot abort another reader using the shared client.
class OwnedHttpClientAdapter implements HttpClientAdapter {
  OwnedHttpClientAdapter({required this.shared, required this.create});
  final HttpClientAdapter shared;
  final HttpClientAdapter Function() create;
  final _active = <HttpClientAdapter>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('HTTP transport is closed');
    if (cancelFuture == null) return shared.fetch(options, requestStream, null);
    final adapter = create();
    _active.add(adapter);
    var finished = false;
    void release() {
      if (finished) return;
      finished = true;
      _active.remove(adapter);
      adapter.close(force: true);
    }

    final cancellation = cancelFuture.asStream().listen((_) => release());
    try {
      final response = await adapter.fetch(
        options,
        requestStream,
        cancelFuture,
      );
      Stream<Uint8List> body() async* {
        try {
          yield* response.stream;
        } finally {
          release();
          await cancellation.cancel();
        }
      }

      return ResponseBody(
        body(),
        response.statusCode,
        statusMessage: response.statusMessage,
        headers: response.headers,
        isRedirect: response.isRedirect,
        redirects: response.redirects,
        onClose: release,
      )..extra.addAll(response.extra);
    } catch (_) {
      release();
      await cancellation.cancel();
      rethrow;
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    shared.close(force: force);
    final active = _active.toList(growable: false);
    _active.clear();
    for (final adapter in active) {
      adapter.close(force: force);
    }
  }
}
