import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// Fixture generation only. Production decryption has an independent Python vector below.
// ignore: implementation_imports
import 'package:archive/src/util/encryption.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/jmcomic/jmcomic_client.dart';
import 'package:triomi/core/source/jmcomic/jmcomic_crypto.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

String encryptJmFixture(Object data, String secret) {
  final plain = utf8.encode(jsonEncode(data));
  final padding = 16 - plain.length % 16;
  final input = Uint8List.fromList([
    ...plain,
    ...List.filled(padding, padding),
  ]);
  final output = Uint8List(input.length);
  final engine = PcAESEngine()
    ..init(
      true,
      PcKeyParameter(
        Uint8List.fromList(
          utf8.encode(md5.convert(utf8.encode(secret)).toString()),
        ),
      ),
    );
  for (var offset = 0; offset < input.length; offset += 16) {
    engine.processBlock(input, offset, output, offset);
  }
  return base64Encode(output);
}

void main() {
  const servers =
      'NSAThS5dKFDE01ywmpjbuR4ShQeXEi0O4lLJ1qWuHiCQlm/+LkOlpnkPyCsDAvP2QMeFb7OtEAf5upSgdUGnYrrGEtIkrWdNW5PUoDSdPydYbwnDL7ELFDEEWFdRIvAi';
  SourceResponse ok(Object data) => SourceResponse(
    statusCode: 200,
    body: jsonEncode({'code': 200, 'data': data}),
  );
  Future<SourceResponse> read(JmcomicClient client) => client.send(
    const SourceRequest(url: '$jmLogicalApi/album?id=101'),
    sourceId: 'jmcomic',
  );
  JmcomicClient client(FakeHttpClient http) {
    final value = JmcomicClient(http);
    addTearDown(value.close);
    return value;
  }

  sourceRuleTest('JM legacy AES-256/MD5/PKCS7 matches an independent PyCryptodome wire vector', () {
    expect(jmToken('1700000000'), '880c64833265ad47a928afcf1b1220f5');
    expect(
      jsonDecode(
        decodeJmPayload(
          '0kdb7kS4CdW32Sq00HekM2jsYY5Yau2i+8l0oHbYFNY/LWDpA04vkZXbhthgf68ueplMj/mBU+NkhurWMd65Hg==',
          'fixture-secret',
        ),
      ),
      {
        'content': [
          {'id': '101', 'name': 'Protocol Fixture'},
        ],
      },
    );
  });

  sourceRuleTest(
    'JM malformed ciphertext fails length, base64 and padding validation',
    () {
      for (final text in [
        '',
        'not base64!',
        base64Encode([1, 2, 3]),
        base64Encode(List.filled(16, 0)),
      ]) {
        expect(
          () => decodeJmPayload(text, 'fixture-secret'),
          throwsFormatException,
        );
      }
    },
  );

  sourceRuleTest('JM signed GET decrypts JSON and discovers only safe official CDN-family hosts', () async {
    final http = FakeHttpClient((request) async {
      expect(request.followRedirects, false);
      expect(
        request.headers.keys.map((s) => s.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(
        request.headers.keys.map((s) => s.toLowerCase()),
        isNot(contains('cookie')),
      );
      if (request.url == jmServerListUrl) {
        return const SourceResponse(statusCode: 200, body: servers);
      }
      expect(Uri.parse(request.url).host, 'www.cdngwc.net');
      expect(Uri.parse(request.url).queryParameters, {
        'id': '101',
        'lang': 'CN',
      });
      final parts = request.headers['Tokenparam']!.split(',');
      expect(parts[1], '2.1.12');
      expect(request.headers['Token'], jmToken(parts[0]));
      return ok(
        encryptJmFixture({
          'id': 101,
          'name': 'Protocol Fixture',
        }, '${parts[0]}$jmTokenSecret'),
      );
    });
    final value = client(http);
    final result = await value.send(
      const SourceRequest(
        url: '$jmLogicalApi/album?id=101',
        headers: {
          'Authorization': 'DO-NOT-FORWARD',
          'Cookie': 'DO-NOT-FORWARD',
        },
      ),
      sourceId: 'jmcomic',
    );
    expect(jsonDecode(result.body)['data'], {
      'id': 101,
      'name': 'Protocol Fixture',
    });
    expect(http.requests, hasLength(2));
  });

  sourceRuleTest('JM unavailable/malformed discovery uses snapshot, never an unverified HTTP target', () async {
    final http = FakeHttpClient(
      (request) async => request.url == jmServerListUrl
          ? const SourceResponse(
              statusCode: 200,
              body: 'invalid encrypted configuration',
            )
          : ok({'id': 101}),
    );
    await read(client(http));
    expect(Uri.parse(http.lastRequest.url).host, jmFallbackHosts.first);
  });

  sourceRuleTest(
    'JM denies account/writes and arbitrary URLs before even server discovery',
    () async {
      final http = FakeHttpClient(
        (_) async => throw StateError('No HTTP expected'),
      );
      final value = client(http);
      for (final url in [
        '$jmLogicalApi/login',
        '$jmLogicalApi/favorite',
        '$jmLogicalApi/daily_chk',
        'https://evil.example/album',
        'http://www.cdnhjk.net/album',
        '$jmLogicalApi:444/album',
        '$jmLogicalApi/album#fragment',
        '$jmLogicalApi/album/../login',
      ]) {
        await expectLater(
          value.send(SourceRequest(url: url), sourceId: 'jmcomic'),
          throwsA(isA<SourceException>()),
        );
      }
      await expectLater(
        value.send(
          const SourceRequest(
            url: '$jmLogicalApi/album',
            method: 'POST',
            body: 'private',
          ),
          sourceId: 'jmcomic',
        ),
        throwsA(isA<SourceException>()),
      );
      expect(http.requests, isEmpty);
    },
  );

  for (final status in [301, 401, 403, 404, 429, 500]) {
    sourceRuleTest(
      'JM HTTP $status is classified, not retried invisibly, and omits server bodies',
      () async {
        final http = FakeHttpClient(
          (request) async => request.url == jmServerListUrl
              ? const SourceResponse(statusCode: 404, body: '')
              : SourceResponse(statusCode: status, body: 'private-remote-body'),
        );
        await expectLater(
          read(client(http)),
          throwsA(
            isA<SourceException>()
                .having(
                  (e) => e.message,
                  'safe message',
                  isNot(contains('private-remote-body')),
                )
                .having((e) => e.type, 'classification', switch (status) {
                  401 || 403 => SourceErrorType.auth,
                  404 => SourceErrorType.notFound,
                  429 => SourceErrorType.rateLimited,
                  _ => SourceErrorType.network,
                }),
          ),
        );
        expect(http.requests, hasLength(2));
      },
    );
  }

  sourceRuleTest(
    'JM source disposal cancels and discards an adapter response arriving late',
    () async {
      final started = Completer<void>(), response = Completer<SourceResponse>();
      final http = FakeHttpClient((request) {
        if (request.url == jmServerListUrl) {
          return Future.value(const SourceResponse(statusCode: 404, body: ''));
        }
        started.complete();
        return response.future;
      });
      final value = client(http);
      final pending = expectLater(read(value), throwsA(isA<SourceException>()));
      await started.future;
      value.close();
      response.complete(ok({'id': 101}));
      await pending;
      expect(http.lastRequest.cancellation!.cancelled, true);
    },
  );
}
