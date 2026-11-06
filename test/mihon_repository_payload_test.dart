import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/mihon_repository.dart';
import 'package:triomi/core/source/mihon_repository_payload.dart';

import 'fixtures/fake_http_client.dart';

List<int> _varint(BigInt value) {
  final bytes = <int>[];
  do {
    final byte = (value & BigInt.from(127)).toInt();
    value >>= 7;
    bytes.add(byte | (value == BigInt.zero ? 0 : 128));
  } while (value != BigInt.zero);
  return bytes;
}

List<int> _message(int field, List<int> bytes) => [
  ..._varint(BigInt.from(field * 8 + 2)),
  ..._varint(BigInt.from(bytes.length)),
  ...bytes,
];
List<int> _text(int field, String text) => _message(field, utf8.encode(text));
List<int> _integer(int field, String value) => [
  ..._varint(BigInt.from(field * 8)),
  ..._varint(BigInt.parse(value).toUnsigned(64)),
];

List<int> _extension({String id = '9223372036854775000', int warning = 2}) => [
  ..._text(1, 'Example'),
  ..._text(2, 'org.example.extension'),
  ..._message(3, [
    ..._text(1, 'https://publisher.example/apk/example.apk'),
    ..._text(2, 'https://publisher.example/icon/example.png'),
  ]),
  ..._text(4, '1.6'),
  ..._integer(5, '106001'),
  ..._text(6, '1.6.1'),
  ..._integer(7, '$warning'),
  ..._message(8, [
    ..._integer(1, id),
    ..._text(2, 'Example source'),
    ..._text(3, 'zh'),
    ..._text(5, 'https://mirror.example'),
    ..._text(7, 'Source message'),
  ]),
];
List<int> _list({String id = '9223372036854775000'}) =>
    _message(1, _extension(id: id));
List<int> _store({String? listUrl, bool embedded = true}) => [
  ..._text(1, 'Declared store'),
  ..._text(2, 'Store'),
  ..._text(3, 'a' * 64),
  ..._message(4, [
    ..._text(1, 'https://publisher.example'),
    ..._text(2, 'https://discord.example'),
  ]),
  if (embedded) ..._message(101, _list()),
  if (listUrl != null) ..._text(102, listUrl),
];

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
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('captured Keiyoushi protobuf retains store identity JM version IDs and desktop JAR', () async {
    // Original wire records for AHottie and JM, selected from the public
    // 2026-11-06 index.pb; repository metadata is copied without substitution.
    final payload = File('test/fixtures/keiyoushi_store_sample.pb')
        .readAsBytesSync();
    final http = FakeHttpClient(
      (request) async =>
          SourceResponse(statusCode: 200, body: '', bodyBytes: payload),
    );
    final index = await MihonRepositoryClient(http)
        .fetch('https://keiyoushi.github.io/extensions/index.pb');
    expect(index.name, 'Keiyoushi');
    expect(
      index.signingKey,
      '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
    );
    expect(index.extensions, hasLength(2));
    final jm = index.extensions.singleWhere(
      (extension) => extension.packageName.endsWith('.jinmantiantang'),
    );
    expect(jm.versionName, '1.6.64');
    expect(jm.versionCode, 106064);
    expect(jm.sources.single.id, '6286738698187452081');
    expect(jm.declaredNsfw, isTrue);
    expect(
      jm.jarUrl,
      'https://github.com/keiyoushi/extensions/releases/download/4591fbc-2/tachiyomi-zh.jinmantiantang-v1.6.64.jar',
    );
    expect(jm.jarSha256, isNull);
  });

  test(
    'full store and list-only decode precise Long IDs and content warnings',
    () {
      final store = MihonRepositoryPayload.decode(_store()) as Map;
      expect(store['name'], 'Declared store');
      expect(store['signingKey'], 'a' * 64);
      expect(store['badgeLabel'], 'Store');
      expect((store['contact'] as Map)['website'], 'https://publisher.example');
      final extension =
          ((store['extensionList'] as Map)['extensions'] as List).single as Map;
      expect(extension['contentWarning'], 'MIXED');
      final source = (extension['sources'] as List).single as Map;
      expect(source['id'], '9223372036854775000');
      expect(source['homeUrl'], '');
      expect(source['mirrorUrls'], ['https://mirror.example']);
      expect(source['message'], 'Source message');
      final list = MihonRepositoryPayload.decode(
        _list(id: '-9223372036854775808'),
      ) as Map;
      expect(list['name'], '');
      expect(list['signingKey'], '');
      expect(
        (((list['extensions'] as List).single as Map)['sources'] as List)
            .single['id'],
        '-9223372036854775808',
      );
    },
  );

  test('valid unknown varint fixed and length fields are skipped without changing extensions', () {
    final decoded = MihonRepositoryPayload.decode([
      ..._store(),
      ..._integer(200, '18446744073709551615'),
      ..._varint(BigInt.from(201 * 8 + 1)),
      ...List.filled(8, 255),
      ..._varint(BigInt.from(202 * 8 + 5)),
      ...List.filled(4, 255),
      ..._message(203, [255, 0, 255]),
    ]) as Map;
    expect(
      ((decoded['extensionList'] as Map)['extensions'] as List),
      hasLength(1),
    );
  });

  test(
    'standalone list skips unknown fields that overlap store field numbers',
    () {
      final decoded = MihonRepositoryPayload.decode([
        ..._list(),
        ..._integer(3, '7'),
        ..._message(101, [255]),
      ]) as Map;
      expect(decoded['signingKey'], '');
      expect(decoded['extensions'], hasLength(1));
    },
  );

  test('malformed protobuf never accepts truncation overflow or invalid known fields', () {
    final cases = <List<int>>[
      [0],
      [0x80],
      [0x0a, 5, 1],
      [...List.filled(9, 0x80), 2],
      [..._store(), ..._varint(BigInt.from(200 * 8 + 1)), 1, 2],
      [..._store(), ..._varint(BigInt.from(200 * 8 + 5)), 1, 2],
      [..._store(), ..._varint(BigInt.from(200 * 8 + 3))],
      [
        ..._store(),
        ..._varint(BigInt.from(200 * 8 + 2)),
        ..._varint(BigInt.parse('18446744073709551615')),
      ],
      [
        ..._store(),
        ..._message(1, [255]),
      ],
      [..._store(), ..._integer(1, '1')],
      [
        ..._text(1, 'No signer'),
        ..._text(2, 'Store'),
        ..._message(101, _list()),
      ],
      _message(1, [..._extension(), ..._integer(7, '4')]),
    ];
    for (final bytes in cases) {
      expect(() => MihonRepositoryPayload.decode(bytes), throwsFormatException);
    }
  });

  test(
    'JSON BOM whitespace and gzip are sniffed independently of URL suffix',
    () {
      final json = utf8.encode('\ufeff  {"extensions": []}');
      expect(
        (MihonRepositoryPayload.decode(json) as Map)['extensions'],
        isEmpty,
      );
      expect(
        (MihonRepositoryPayload.decode(gzip.encode(json)) as Map)['extensions'],
        isEmpty,
      );
      expect(
        (MihonRepositoryPayload.decode(gzip.encode(_store())) as Map)['name'],
        'Declared store',
      );
      expect(
        () => MihonRepositoryPayload.decode([0x1f, 0x8b, 0, 0]),
        throwsFormatException,
      );
    },
  );

  test(
    'raw and streamed gzip expansion independently enforce the 16 MiB bound',
    () {
      expect(
        () => MihonRepositoryPayload.decode(
          Uint8List(MihonRepositoryPayload.maxBytes + 1),
        ),
        throwsFormatException,
      );
      final bomb = gzip.encode(Uint8List(MihonRepositoryPayload.maxBytes + 1));
      expect(bomb.length, lessThan(100000));
      expect(() => MihonRepositoryPayload.decode(bomb), throwsFormatException);
    },
  );

  test('repo index_v2 and redirected binary resources preserve identity and actual URL base', () async {
    final http = FakeHttpClient((request) async {
      expect(request.responseBytes, isTrue);
      expect(request.followRedirects, isFalse);
      if (request.url == 'https://store.example/repo.json') {
        return SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'meta': {
              'name': 'Original publisher',
              'signingKeyFingerprint': 'original-pin',
            },
            'index_v2': 'catalog',
          }),
        );
      }
      expect(request.url, 'https://store.example/catalog');
      return SourceResponse(
        statusCode: 200,
        body: '',
        bodyBytes: gzip.encode(_store()),
        url: 'https://cdn.example/releases/current/catalog',
      );
    });
    final index = await MihonRepositoryClient(http)
        .fetch('https://store.example/repo.json');
    expect(index.sourceUrl, 'https://store.example/repo.json');
    expect(index.name, 'Original publisher');
    expect(index.signingKey, 'original-pin');
    expect(
      index.extensions.single.apkUrl,
      'https://publisher.example/apk/example.apk',
    );
    expect(
      index.extensions.single.iconUrl,
      'https://publisher.example/icon/example.png',
    );
    expect(index.extensions.single.sources.single.id, '9223372036854775000');
    expect(index.extensions.single.declaredNsfw, isTrue);
  });

  test('external ExtensionList has precedence over embedded list and preserves declared signing', () async {
    final http = FakeHttpClient(
      (request) async => request.url.endsWith('/store')
          ? SourceResponse(
              statusCode: 200,
              body: '',
              bodyBytes: _store(listUrl: 'external', embedded: true),
            )
          : SourceResponse(
              statusCode: 200,
              body: '',
              bodyBytes: _list(id: '1473815169283746501'),
            ),
    );
    final index = await MihonRepositoryClient(http)
        .fetch('https://store.example/store');
    expect(http.requests.map((request) => request.url), [
      'https://store.example/store',
      'https://store.example/external',
    ]);
    expect(index.name, 'Declared store');
    expect(index.signingKey, 'a' * 64);
    expect(index.extensions.single.sources.single.id, '1473815169283746501');
  });

  test(
    'standalone ExtensionList does not fabricate publisher name or signing key',
    () async {
      final http = FakeHttpClient(
        (request) async =>
            SourceResponse(statusCode: 200, body: '', bodyBytes: _list()),
      );
      final index = await MihonRepositoryClient(http)
          .fetch('https://store.example/list');
      expect(index.name, '');
      expect(index.signingKey, '');
      expect(index.extensions, hasLength(1));
    },
  );

  test('HTTP redirects reject unsafe targets before issuing another request and bound loops', () async {
    for (final target in [
      'http://unsafe.example',
      'https://user:secret@unsafe.example',
      'https://safe.example/#fragment',
    ]) {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 302,
          body: '',
          headers: {'location': target},
        ),
      );
      await expectLater(
        MihonRepositoryClient(http).fetch('https://store.example/list'),
        throwsA(isA<MihonRepositoryParseException>()),
      );
      expect(http.requests, hasLength(1));
    }
    final loop = FakeHttpClient(
      (request) async => const SourceResponse(
        statusCode: 302,
        body: '',
        headers: {'location': '/again'},
      ),
    );
    await expectLater(
      MihonRepositoryClient(loop).fetch('https://store.example/list'),
      throwsA(isA<MihonRepositoryParseException>()),
    );
    expect(loop.requests, hasLength(6));
    final descriptors = FakeHttpClient(
      (request) async => SourceResponse(
        statusCode: 200,
        body: '',
        bodyBytes: _store(listUrl: 'again', embedded: false),
      ),
    );
    await expectLater(
      MihonRepositoryClient(descriptors).fetch('https://store.example/store'),
      throwsA(isA<MihonRepositoryParseException>()),
    );
    expect(descriptors.requests, hasLength(3));
  });

  test('Dio raw response retains protobuf bytes and public GitHub index API recovery', () async {
    for (final partialBody in [false, true]) {
      final adapter = _Adapter((options) {
        expect(options.responseType, ResponseType.stream);
        expect(options.followRedirects, isFalse);
        if (options.uri.host == 'raw.githubusercontent.com') {
          final error = DioException.receiveTimeout(
            requestOptions: options,
            timeout: const Duration(seconds: 1),
          );
          if (!partialBody) throw error;
          Stream<Uint8List> interrupted() async* {
            yield Uint8List.fromList([1, 2]);
            throw error;
          }

          return ResponseBody(interrupted(), 200);
        }
        expect(
          options.uri.toString(),
          'https://api.github.com/repos/owner/repo/contents/catalog?ref=main',
        );
        return ResponseBody.fromBytes(_store(), 200);
      });
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      final index = await MihonRepositoryClient(http)
          .fetch('https://raw.githubusercontent.com/owner/repo/main/catalog');
      expect(
        index.extensions.single.apkUrl,
        'https://publisher.example/apk/example.apk',
      );
      expect(adapter.requests, hasLength(2));
    }
  });

  test(
    'Dio raw stream stops at the byte limit and leaves text requests unchanged',
    () async {
      var canceled = false;
      var emitted = 0;
      final adapter = _Adapter((options) {
        if (options.uri.path == '/text') {
          expect(options.responseType, ResponseType.plain);
          return ResponseBody.fromString('unchanged', 200);
        }
        Stream<Uint8List> oversized() async* {
          try {
            while (emitted < 100) {
              emitted++;
              yield Uint8List(1024 * 1024);
            }
          } finally {
            canceled = true;
          }
        }

        return ResponseBody(oversized(), 200);
      });
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      await expectLater(
        MihonRepositoryClient(http).fetch('https://store.example/list'),
        throwsA(isA<SourceException>()),
      );
      expect(canceled, isTrue);
      expect(emitted, 17);
      final text = await http.send(
        const SourceRequest(url: 'https://store.example/text'),
        sourceId: 'unchanged',
      );
      expect(text.body, 'unchanged');
      expect(text.bodyBytes, isNull);
    },
  );

  test('Dio byte responses follow safe manual redirects and reject HTTPS downgrades', () async {
    for (final downgrade in [false, true]) {
      final adapter = _Adapter((options) {
        if (options.uri.host == 'store.example') {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [
                '${downgrade ? 'http' : 'https'}://delivery.example/catalog',
              ],
            },
          );
        }
        expect(options.uri.toString(), 'https://delivery.example/catalog');
        return ResponseBody.fromBytes(_store(), 200);
      });
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      final result = MihonRepositoryClient(http)
          .fetch('https://store.example/catalog');
      if (downgrade) {
        await expectLater(
          result,
          throwsA(isA<MihonRepositoryParseException>()),
        );
        expect(adapter.requests, hasLength(1));
      } else {
        expect((await result).extensions, hasLength(1));
        expect(adapter.requests, hasLength(2));
      }
    }
  });

  test('raw response body cancellation aborts only its request and allows another fetch', () async {
    final cancellation = SourceRequestCancellation();
    final started = Completer<void>();
    final stopped = Completer<void>();
    final adapter = _Adapter((options) {
      if (options.uri.path == '/next') {
        return ResponseBody.fromBytes(_store(), 200);
      }
      Stream<Uint8List> held() async* {
        try {
          started.complete();
          yield Uint8List.fromList([1]);
          await options.cancelToken!.whenCancel;
        } finally {
          stopped.complete();
        }
      }

      return ResponseBody(held(), 200);
    });
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    final pending = cancellation.run(
      () => MihonRepositoryClient(http).fetch('https://store.example/held'),
    );
    final rejected = expectLater(
      pending,
      throwsA(
        isA<SourceException>().having(
          (error) => error.cause,
          'cause',
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      ),
    );
    await started.future;
    cancellation.cancel();
    await rejected;
    await stopped.future.timeout(const Duration(seconds: 2));
    final next = await MihonRepositoryClient(http)
        .fetch('https://store.example/next');
    expect(next.extensions, hasLength(1));
  });
}
