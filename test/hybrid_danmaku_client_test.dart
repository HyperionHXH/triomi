import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_client.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_codec.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_models.dart';

import 'fixtures/fake_http_client.dart';

// These IDs/field units and shapes are the public Frieren responses recorded
// in docs/DANMAKU.md. Bodies are minimal protocol fixtures, not live counts.
const _firstBili = DanmakuEpisodeChoice(
  provider: DanmakuProviderKind.bilibili,
  id: '779775',
  title: '第1话',
  number: 1,
  cid: 1339446971,
  aid: 450096728,
  durationMs: 1559933,
);
const _firstAnimeko = DanmakuEpisodeChoice(
  provider: DanmakuProviderKind.animeko,
  id: '1227087',
  title: '第1话',
  number: 1,
);

List<int> _varint(int value) {
  final out = <int>[];
  do {
    final part = value & 127;
    value >>= 7;
    out.add(part | (value == 0 ? 0 : 128));
  } while (value != 0);
  return out;
}

List<int> _number(int field, int value) => [
  ..._varint(field << 3),
  ..._varint(value),
];
List<int> _blob(int field, List<int> bytes) => [
  ..._varint((field << 3) | 2),
  ..._varint(bytes.length),
  ...bytes,
];
List<int> _segment({
  int time = 1234,
  int mode = 1,
  int color = 0xffffff,
  String text = '勇者一行',
  List<int> extra = const [],
}) => _blob(1, [
  ..._number(2, time),
  ..._number(3, mode),
  ..._number(5, color),
  ..._blob(6, utf8.encode('public-hash')),
  ..._blob(7, utf8.encode(text)),
  ...extra,
]);

Map<String, Object?> _episode(
  int id,
  String title, {
  int section = 0,
  int pv = 0,
}) => {
  'id': id,
  'title': title,
  'long_title': '冒险的结束',
  'cid': id == 779775 ? 1339446971 : id + 100,
  'aid': id == 779775 ? 450096728 : id + 200,
  'duration': 1559933,
  'section_type': section,
  'pv': pv,
};
Object _season(List<Object?> rows) => {
  'code': 0,
  'result': {'season_id': 46089, 'episodes': rows},
};
const _month = [
  {
    'title': 'same misleading title',
    'sites': [
      {'site': 'bangumi', 'id': '999999'},
      {'site': 'bilibili', 'id': '12345'},
    ],
  },
  {
    'title': '葬送のフリーレン',
    'sites': [
      {'site': 'bangumi', 'id': '400602'},
      {'site': 'bilibili', 'id': '21087073'},
      {'site': 'bilibili_hk_mo_tw', 'id': '99999'},
    ],
  },
];
Object _animeko({
  int time = 1234,
  int color = -1,
  String location = 'NORMAL',
}) => {
  'danmakuList': [
    {
      'id': 'public-id',
      'senderId': 'sender',
      'danmakuInfo': {
        'playTime': time,
        'color': color,
        'text': '辛美尔',
        'location': location,
      },
    },
  ],
};
Matcher _sourceError(SourceErrorType type) =>
    isA<SourceException>().having((e) => e.type, 'type', type);

class _Http extends FakeHttpClient {
  _Http(this.route)
    : super((_) async => throw StateError('Unexpected text request'));
  final FutureOr<Object> Function(Uri uri) route;
  int active = 0;
  int maxActive = 0;
  final owners = <SourceRequestCancellation?>[];
  final sourceIds = <String>[];
  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async {
    requests.add(
      SourceRequest(
        url: url,
        headers: headers,
        followRedirects: followRedirects,
      ),
    );
    owners.add(SourceRequestCancellation.current);
    sourceIds.add(sourceId);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      final raw = await route(Uri.parse(url));
      if (raw is SourceByteStream) return raw;
      final bytes = raw is List<int> ? raw : utf8.encode(jsonEncode(raw));
      return SourceByteStream(
        stream: Stream.value(bytes),
        url: url,
        contentLength: bytes.length,
      );
    } finally {
      active--;
    }
  }
}

class _Bangumi extends BangumiPublicClient {
  _Bangumi(super.http, {this.date = '2023-09-29', this.rows = const []});
  final String date;
  final List<Map<String, Object?>> rows;
  final offsets = <int>[];
  @override
  Future<Map<String, Object?>> subject(
    String id, {
    bool refresh = false,
  }) async => {'id': int.parse(id), 'date': date};
  @override
  Future<List<Map<String, Object?>>> episodes(
    String id, {
    int offset = 0,
    int limit = 100,
  }) async {
    offsets.add(offset);
    return rows.skip(offset).take(limit).toList();
  }
}

HybridDanmakuClient _client(_Http http, {_Bangumi? bangumi}) =>
    HybridDanmakuClient(http: http, bangumi: bangumi ?? _Bangumi(http));

void main() {
  group('strict codecs', () {
    test(
      'Bilibili uses progress milliseconds, RGB and documented field IDs',
      () {
        final rows = HybridDanmakuCodec.bilibiliSegment(
          _segment(
            time: 12345,
            mode: 5,
            color: 0x12abcd,
            extra: [
              ..._number(1, 123456),
              ..._blob(22, [1, 2, 3]),
            ],
          ),
        );
        expect(rows, hasLength(1));
        expect(rows.single.time, 12.345);
        expect(rows.single.text, '勇者一行');
        expect(rows.single.mode, 5);
        expect(rows.single.color, 0x12abcd);
        expect(rows.single.user, 'public-hash');
      },
    );
    test(
      'proto3 omitted progress/color mean zero, unknown uint64 is skipped',
      () {
        final rows = HybridDanmakuCodec.bilibiliSegment(
          _blob(1, [
            ..._number(3, 1),
            ..._blob(7, utf8.encode('black at zero')),
            8,
            ...List.filled(9, 255),
            1,
          ]),
        );
        expect(rows.single.time, 0);
        expect(rows.single.color, 0);
      },
    );
    test(
      'Animeko signed ARGB, milliseconds and location have exact meanings',
      () {
        for (final entry in {'NORMAL': 1, 'TOP': 5, 'BOTTOM': 4}.entries) {
          final rows = HybridDanmakuCodec.animeko(
            _animeko(time: 2500, color: -65536, location: entry.key),
          );
          expect(rows.single.time, 2.5);
          expect(rows.single.color, 0xff0000);
          expect(rows.single.mode, entry.value);
        }
      },
    );
    test('valid empty pools differ from invalid response shapes', () {
      expect(HybridDanmakuCodec.bilibiliSegment([]), isEmpty);
      expect(HybridDanmakuCodec.animeko({'danmakuList': <Object?>[]}), isEmpty);
      for (final value in <Object?>[
        null,
        <Object?>[],
        <String, Object?>{},
        {
          'danmakuList': <Object?>[null],
        },
      ]) {
        expect(() => HybridDanmakuCodec.animeko(value), throwsFormatException);
      }
    });
    test(
      'advanced/script modes, unsafe text/time/color are never comments',
      () {
        for (final mode in [0, 2, 3, 6, 7, 8, 9]) {
          expect(
            HybridDanmakuCodec.bilibiliSegment(_segment(mode: mode)),
            isEmpty,
          );
        }
        expect(
          HybridDanmakuCodec.bilibiliSegment(_segment(time: 21600001)),
          isEmpty,
        );
        expect(
          HybridDanmakuCodec.bilibiliSegment(_segment(color: 0x1000000)),
          isEmpty,
        );
        expect(
          HybridDanmakuCodec.bilibiliSegment(_segment(text: 'a\u0000b')),
          isEmpty,
        );
        expect(HybridDanmakuCodec.animeko(_animeko(time: -1)), isEmpty);
        expect(
          HybridDanmakuCodec.animeko(_animeko(location: 'SCRIPT')),
          isEmpty,
        );
      },
    );
    test(
      'truncated, overflowing, wrong-wire and noncanonical varints fail',
      () {
        for (final bytes in <List<int>>[
          [10, 5, 16, 1],
          [10, 1, 128],
          [0],
          [11],
          [10, 2, 18, 0],
          [128, 0],
          [...List.filled(10, 255), 0],
          _blob(1, [16, ...List.filled(9, 255), 2]),
          _blob(1, [16, ...List.filled(9, 255), 1]),
          _blob(1, [16, 128, 0]),
          _blob(1, [58, 2, 0xc3, 0x28]),
        ]) {
          expect(
            () => HybridDanmakuCodec.bilibiliSegment(bytes),
            throwsFormatException,
          );
        }
      },
    );
    test(
      'compressed XML is rejected instead of unbounded decompression/fallback',
      () {
        final xml = utf8.encode('<i><d p="1.2,1,25,16777215">hello</d></i>');
        for (final bytes in [
          xml,
          gzip.encode(xml),
          zlib.encode(xml),
          ZLibEncoder(raw: true).convert(xml),
        ]) {
          expect(
            () => HybridDanmakuCodec.bilibiliSegment(bytes),
            throwsFormatException,
          );
        }
      },
    );
    test(
      'byte, entry, text and caller remaining-count budgets are enforced',
      () {
        expect(
          () => HybridDanmakuCodec.bilibiliSegment(
            List.filled(HybridDanmakuCodec.maxBytes + 1, 0),
          ),
          throwsFormatException,
        );
        expect(
          () => HybridDanmakuCodec.bilibiliSegment(_segment(text: 'x' * 2001)),
          throwsFormatException,
        );
        expect(
          () => HybridDanmakuCodec.bilibiliSegment(_segment(), maxCount: 0),
          throwsFormatException,
        );
        expect(
          () => HybridDanmakuCodec.bilibiliSegment([
            for (var i = 0; i <= HybridDanmakuCodec.maxComments; i++) ...[
              10,
              0,
            ],
          ]),
          throwsFormatException,
        );
      },
    );
  });

  test(
    'canonical monthly map resolves media md to real season ss, never title',
    () async {
      final http = _Http((uri) {
        if (uri.host == 'raw.githubusercontent.com') {
          expect(uri.path, endsWith('/2023/09.json'));
          return _month;
        }
        if (uri.path == '/pgc/review/user') {
          expect(uri.queryParameters, {'media_id': '21087073'});
          return {
            'code': 0,
            'result': {
              'media': {'season_id': 46089},
            },
          };
        }
        expect(uri.queryParameters, {'season_id': '46089'});
        return _season([_episode(779775, '1'), _episode(123, 'PV', pv: 1)]);
      });
      final client = _client(http);
      final rows = await client.bilibiliEpisodesForSubject('400602');
      expect(rows.first.id, '779775');
      expect(rows.first.cid, 1339446971);
      expect(rows.first.aid, 450096728);
      expect(rows.first.durationMs, 1559933);
      expect(rows.first.number, 1);
      expect(rows.first.special, isFalse);
      expect(rows.last.special, isTrue);
      expect(rows.last.number, isNull);
      await client.bilibiliEpisodesForSubject('400602');
      expect(http.requests, hasLength(3));
      for (final request in http.requests) {
        expect(request.method, 'GET');
        expect(request.followRedirects, isFalse);
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(anyOf(contains('cookie'), contains('authorization'))),
        );
        expect(request.url, isNot(contains('dandan')));
      }
    },
  );

  test(
    'monthly mapping inspects at most adjacent months and caches not-found',
    () async {
      final months = <String>[];
      final http = _Http((uri) {
        months.add(uri.path);
        return <Object>[];
      });
      final client = _client(http, bangumi: _Bangumi(http, date: '2023-01-01'));
      expect(await client.bilibiliEpisodesForSubject('400602'), isEmpty);
      expect(months, hasLength(3));
      expect(months[0], endsWith('/2023/01.json'));
      expect(months[1], endsWith('/2022/12.json'));
      expect(months[2], endsWith('/2023/02.json'));
      await client.bilibiliEpisodesForSubject('400602');
      expect(months, hasLength(3));
    },
  );

  test(
    'raw timeout uses exact GitHub public resource API, no arbitrary proxy',
    () async {
      final http = _Http((uri) {
        if (uri.host == 'raw.githubusercontent.com') {
          throw const SourceException(
            sourceId: 'transport',
            type: SourceErrorType.timeout,
          );
        }
        if (uri.host == 'api.github.com') {
          expect(
            uri.path,
            '/repos/bangumi-data/bangumi-data/contents/data/items/2023/09.json',
          );
          expect(uri.queryParameters, {'ref': 'master'});
          return _month;
        }
        if (uri.path == '/pgc/review/user') {
          return {
            'code': 0,
            'result': {
              'media': {'season_id': 46089},
            },
          };
        }
        return _season([_episode(779775, '1')]);
      });
      expect(
        await _client(http).bilibiliEpisodesForSubject('400602'),
        hasLength(1),
      );
      expect(
        http.requests[1].headers['Accept'],
        'application/vnd.github.raw+json',
      );
    },
  );

  test('official ep correction includes supplemental OP sections without normal auto matching', () async {
    final http = _Http(
      (_) => {
        'code': 0,
        'result': {
          'episodes': [_episode(779775, '1')],
          'section': [
            {
              'title': '主题曲',
              'episodes': [
                {
                  'id': 780514,
                  'title': 'OP',
                  'long_title': 'YOASOBI - 勇者(The Brave)',
                  'cid': 1283923016,
                  'aid': 364104511,
                  'duration': 205000,
                  'section_type': 2,
                  'pv': 0,
                },
              ],
            },
          ],
        },
      },
    );
    final rows = await _client(http)
        .bilibiliEpisodes('https://www.bilibili.com/bangumi/play/ep780514');
    final op = rows.singleWhere((episode) => episode.id == '780514');
    expect((op.cid, op.aid, op.durationMs), (1283923016, 364104511, 205000));
    expect((op.special, op.number), (true, null));
    expect(rows.singleWhere((episode) => !episode.special).id, '779775');
  });

  test(
    'manual official md/ss/ep and tracking params preserve exact typed ID',
    () async {
      final http = _Http((uri) {
        expect(uri.queryParameters, {'ep_id': '779775'});
        return _season([_episode(779775, '1')]);
      });
      final rows = await _client(http).bilibiliEpisodes(
        'https://www.bilibili.com/bangumi/play/ep779775?from=search#reply',
      );
      expect(rows.single.id, '779775');
      expect(http.requests.single.url, isNot(contains('search')));
      for (final value in [
        '46089',
        'https://evil.example/bangumi/play/ss46089',
        'https://www.bilibili.com.evil.example/bangumi/play/ss46089',
        'http://www.bilibili.com/bangumi/play/ss46089',
        'https://secret@www.bilibili.com/bangumi/play/ss46089',
        'https://www.bilibili.com:8443/bangumi/play/ss46089',
        'https://www.bilibili.com/video/BV18j411i7iu',
        'ep0',
      ]) {
        await expectLater(
          _client(http).bilibiliEpisodes(value),
          throwsA(_sourceError(SourceErrorType.parse)),
        );
      }
      expect(http.requests, hasLength(1));
    },
  );

  test(
    'special entries and duplicate ordinary numbers retain unique upstream IDs',
    () async {
      final http = _Http(
        (_) => _season([
          _episode(779775, '1'),
          _episode(779776, '1'),
          _episode(779777, '1', section: 1),
          _episode(779778, '1.5'),
        ]),
      );
      final rows = await _client(http).bilibiliEpisodes('ss46089');
      expect(rows.map((row) => row.id).toSet(), hasLength(4));
      expect(
        rows.where((row) => !row.special && row.number == 1),
        hasLength(2),
      );
      expect(
        rows.skip(2).every((row) => row.special && row.number == null),
        isTrue,
      );
      await expectLater(
        _client(http).bilibiliEpisodes('ep999'),
        throwsA(_sourceError(SourceErrorType.parse)),
      );
    },
  );

  test(
    'Animeko keeps real Bangumi IDs, type and sort without inferring index',
    () async {
      final http = _Http(
        (_) => throw StateError('No danmaku request expected'),
      );
      final bgm = _Bangumi(
        http,
        rows: [
          {'id': 1227087, 'type': 0, 'sort': 1, 'name_cn': '冒险的结束'},
          {'id': 1234567, 'type': 1, 'sort': 1, 'name': 'SP'},
          {'id': 1234568, 'type': 0, 'sort': 1, 'name': 'Alternative'},
        ],
      );
      final rows = await _client(http, bangumi: bgm).animekoEpisodes('400602');
      expect(rows.map((e) => e.id), ['1227087', '1234567', '1234568']);
      expect(rows[1].special, isTrue);
      expect(rows.where((e) => !e.special && e.number == 1), hasLength(2));
      expect(http.requests, isEmpty);
    },
  );

  test('Bilibili loads every duration segment with bounded concurrency then caches', () async {
    final http = _Http((uri) async {
      await Future<void>.delayed(Duration.zero);
      expect(uri.path, '/x/v2/dm/web/seg.so');
      expect(uri.queryParameters['oid'], '1339446971');
      expect(uri.queryParameters['pid'], '450096728');
      final index = int.parse(uri.queryParameters['segment_index']!);
      return _segment(time: (index - 1) * 360000 + 1000);
    });
    final client = _client(http);
    final rows = await client.comments(_firstBili);
    expect(rows, hasLength(5));
    expect(rows.map((row) => row.time), [1, 361, 721, 1081, 1441]);
    expect(http.maxActive, lessThanOrEqualTo(2));
    expect(http.maxActive, 2);
    await client.comments(_firstBili);
    expect(http.requests, hasLength(5));
    expect(http.owners.every((owner) => owner != null), isTrue);
  });

  test(
    'one failed Bilibili segment fails source and is never cached as complete',
    () async {
      var fail = true;
      final http = _Http((uri) {
        if (fail && uri.queryParameters['segment_index'] == '2') {
          throw const SourceException(
            sourceId: 'danmaku-bilibili',
            type: SourceErrorType.auth,
          );
        }
        return _segment();
      });
      final client = _client(http);
      await expectLater(
        client.comments(_firstBili),
        throwsA(_sourceError(SourceErrorType.auth)),
      );
      fail = false;
      expect(await client.comments(_firstBili), hasLength(5));
      expect(
        http.requests.where((r) => r.url.endsWith('segment_index=1')).length,
        greaterThanOrEqualTo(2),
      );
    },
  );

  test('Animeko mirror is failover only and valid empty success does not fail over', () async {
    final http = _Http((uri) {
      if (uri.host == 'danmaku-cn.myani.org') {
        throw const SourceException(
          sourceId: 'transport',
          type: SourceErrorType.timeout,
        );
      }
      expect(uri.host, 'danmaku-global.myani.org');
      expect(uri.path, '/v1/danmaku/1227087');
      return _animeko();
    });
    expect(await _client(http).comments(_firstAnimeko), hasLength(1));
    expect(http.requests, hasLength(2));
    final empty = _Http((_) => {'danmakuList': <Object?>[]});
    expect(await _client(empty).comments(_firstAnimeko), isEmpty);
    expect(empty.requests, hasLength(1));
    for (final type in [
      SourceErrorType.auth,
      SourceErrorType.rateLimited,
      SourceErrorType.notFound,
      SourceErrorType.parse,
    ]) {
      final failed = _Http(
        (_) => throw SourceException(sourceId: 'transport', type: type),
      );
      await expectLater(
        _client(failed).comments(_firstAnimeko),
        throwsA(_sourceError(type)),
      );
      expect(failed.requests, hasLength(1));
    }
  });

  test('cancellation interrupts stream, cancels transport owner and cannot cache late data', () async {
    final started = Completer<void>();
    final stream = StreamController<List<int>>();
    final closed = Completer<void>();
    stream.onListen = started.complete;
    stream.onCancel = closed.complete;
    var stalled = true;
    final http = _Http((uri) {
      if (!stalled) return _animeko();
      return SourceByteStream(stream: stream.stream, url: uri.toString());
    });
    final client = _client(http);
    final owner = SourceRequestCancellation();
    final future = owner.run(() => client.comments(_firstAnimeko));
    final assertion = expectLater(future, throwsA(isA<SourceException>()));
    await started.future;
    owner.cancel();
    await assertion;
    await closed.future.timeout(const Duration(seconds: 1));
    expect(http.requests, hasLength(1));
    stalled = false;
    expect(await client.comments(_firstAnimeko), hasLength(1));
    expect(http.requests, hasLength(2));
    await stream.close();
  });

  test(
    'already cancelled operations make no request, even for cached values',
    () async {
      final http = _Http((_) => _animeko());
      final client = _client(http);
      await client.comments(_firstAnimeko);
      final owner = SourceRequestCancellation()..cancel();
      await expectLater(
        owner.run(() => client.comments(_firstAnimeko)),
        throwsA(isA<SourceException>()),
      );
      expect(http.requests, hasLength(1));
    },
  );

  test(
    'declared and streamed oversize responses abort before decoding',
    () async {
      var subscribed = false;
      var cancelled = false;
      final stream = StreamController<List<int>>();
      stream.onListen = () {
        subscribed = true;
      };
      stream.onCancel = () {
        cancelled = true;
      };
      final http = _Http(
        (uri) => SourceByteStream(
          stream: stream.stream,
          url: uri.toString(),
          contentLength: 2 * 1024 * 1024 + 1,
        ),
      );
      await expectLater(
        _client(http).comments(_firstAnimeko),
        throwsA(_sourceError(SourceErrorType.parse)),
      );
      expect(subscribed, isTrue);
      expect(cancelled, isTrue);
      await stream.close();
      final chunked = _Http(
        (uri) => SourceByteStream(
          stream: Stream.fromIterable([
            List.filled(1024 * 1024, 32),
            List.filled(1024 * 1024 + 1, 32),
          ]),
          url: uri.toString(),
        ),
      );
      await expectLater(
        _client(chunked).comments(_firstAnimeko),
        throwsA(_sourceError(SourceErrorType.parse)),
      );
    },
  );

  test('protocol errors, HTTP restrictions and missing duration remain real failures', () async {
    for (final code in [-403, -412, -10403, -101]) {
      final http = _Http((_) => {'code': code, 'message': 'restricted'});
      await expectLater(
        _client(http).bilibiliEpisodes('ss46089'),
        throwsA(_sourceError(SourceErrorType.auth)),
      );
    }
    final forbidden = _Http(
      (uri) => SourceByteStream(
        stream: const Stream.empty(),
        statusCode: 403,
        url: uri.toString(),
      ),
    );
    await expectLater(
      _client(forbidden).comments(_firstAnimeko),
      throwsA(_sourceError(SourceErrorType.auth)),
    );
    expect(forbidden.requests, hasLength(1));
    final http = _Http((_) => throw StateError('Must fail before request'));
    await expectLater(
      _client(http).comments(
        const DanmakuEpisodeChoice(
          provider: DanmakuProviderKind.bilibili,
          id: '779775',
          title: 'Missing metadata',
        ),
      ),
      throwsA(_sourceError(SourceErrorType.parse)),
    );
    expect(http.requests, isEmpty);
  });

  test('bounded LRU evicts old episode comments rather than persisting indefinitely', () async {
    final http = _Http((_) => _animeko());
    final client = _client(http);
    for (var id = 1; id <= 17; id++) {
      await client.comments(
        DanmakuEpisodeChoice(
          provider: DanmakuProviderKind.animeko,
          id: '$id',
          title: 'episode $id',
        ),
      );
    }
    expect(http.requests, hasLength(17));
    await client.comments(
      const DanmakuEpisodeChoice(
        provider: DanmakuProviderKind.animeko,
        id: '1',
        title: 'episode 1',
      ),
    );
    expect(http.requests, hasLength(18));
  });
}
