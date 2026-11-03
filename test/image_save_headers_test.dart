import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/widgets/image_viewer.dart';

void main() {
  test('gallery-save byte loading retains chapter Referer and explicit absent UA', () async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    final payload = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR4nGOUs4n6z8DAwAAACb0BtVhLOK8AAAAASUVORK5CYII=');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.headers.value('referer') != 'https://reader.example/chapter/2' ||
          request.headers.value('user-agent') != null) {
        request.response.statusCode = HttpStatus.forbidden;
      } else {
        request.response.add(payload);
      }
      await request.response.close();
    });
    final http = DioSourceHttpClient();
    try {
      final url = 'http://127.0.0.1:${server.port}/page.png';
      expect(await loadImageBytes(url, sourceId: 'source', http: http), isNull);
      expect(await loadImageBytes(url, sourceId: 'source', http: http, headers: const {
        'Referer': 'https://reader.example/chapter/2', 'User-Agent': '',
      }), payload);
    } finally {
      http.close();
      await server.close(force: true);
      HttpOverrides.global = previous;
    }
  });
}
