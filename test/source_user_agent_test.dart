import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';

void main() {
  test('explicit plugin UA omission removes both host and Dart defaults on text and image requests', () async {
    final before = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final observed = <String, String?>{};
    server.listen((request) async {
      observed[request.uri.path] = request.headers.value('user-agent');
      request.response.add(utf8.encode('ok'));
      await request.response.close();
    });
    final client = DioSourceHttpClient();
    final origin = 'http://127.0.0.1:${server.port}';
    try {
      await client.send(SourceRequest(url: '$origin/default'), sourceId: 'copymanga');
      await client.send(SourceRequest(url: '$origin/none', omitUserAgent: true,
        headers: const {'user-agent': 'must-not-survive'}), sourceId: 'copymanga');
      await client.fetchBytes('$origin/image', sourceId: 'copymanga',
        headers: const {'User-Agent': ''});
      expect(observed['/default'], 'Triomi/0.1.0');
      expect(observed.containsKey('/none'), isTrue);
      expect(observed['/none'], isNull);
      expect(observed.containsKey('/image'), isTrue);
      expect(observed['/image'], isNull);
    } finally {
      client.close();
      await server.close(force: true);
      HttpOverrides.global = before;
    }
  });
}
