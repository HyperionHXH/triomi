import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final ResponseBody Function(RequestOptions) reply;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    expect(options.followRedirects, isFalse);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'HTTPS downgrade is rejected before an HTTP request is issued',
    () async {
      final adapter = _Adapter(
        (_) => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['http://insecure.test/rule.json'],
          },
        ),
      );
      final client = DioSourceHttpClient(
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(client.close);
      await expectLater(
        client.downloadRuleBytes(
          'https://safe.test/rule.json',
          sourceId: 'test',
        ),
        throwsStateError,
      );
      expect(adapter.requests.map((r) => r.uri.scheme), ['https']);
    },
  );
  test('relative HTTPS redirect is followed; loops are bounded', () async {
    final adapter = _Adapter(
      (r) => r.uri.path == '/rule.json'
          ? ResponseBody.fromString('{}', 200)
          : ResponseBody.fromString(
              '',
              302,
              headers: {
                'location': ['/rule.json'],
              },
            ),
    );
    final client = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(client.close);
    final response = await client.downloadRuleBytes(
      'https://safe.test/start',
      sourceId: 'test',
    );
    expect(response.url, 'https://safe.test/rule.json');
    expect(await response.stream.expand((bytes) => bytes).toList(), [123, 125]);
    final loop = _Adapter(
      (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['/loop'],
        },
      ),
    );
    final looping = DioSourceHttpClient(dio: Dio()..httpClientAdapter = loop);
    addTearDown(looping.close);
    await expectLater(
      looping.downloadRuleBytes('https://safe.test/loop', sourceId: 'test'),
      throwsStateError,
    );
    expect(loop.requests.length, 6);
  });
}
