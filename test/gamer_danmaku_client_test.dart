import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/player/data/gamer_danmaku_client.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_models.dart';

import 'fixtures/fake_http_client.dart';

// Minimal recorded public protocol shapes, never fixtures of live counts.
// 百合是我的工作！: Bangumi381666, ACG128544, anime113239, video33254.
const _choice = DanmakuEpisodeChoice(
  provider: DanmakuProviderKind.gamer,
  id: '33254',
  title: '第1话',
  number: 1,
);
const _month = [
  {
    'title': '私の百合はお仕事です！',
    'titleTranslate': {
      'zh-Hant': ['百合是我的工作！'],
    },
    'sites': [
      {'site': 'bangumi', 'id': '381666'},
      {'site': 'gamer', 'id': '128544'},
      {'site': 'gamer_hk', 'id': '128544'},
    ],
  },
];
const _search = {
  'history': <Object?>[],
  'anime': [
    // A matching title alone cannot override exact canonical ACG identity.
    {'acg_sn': 9, 'anime_sn': 8, 'video_sn': 7, 'title': '百合是我的工作！'},
    {
      'acg_sn': 128544,
      'anime_sn': 113239,
      'video_sn': 33254,
      'title': '百合是我的工作！',
    },
  ],
};
Object _video({
  int acg = 128544,
  int anime = 113239,
  int total = 2,
  List<Object?>? episodes,
}) => {
  'data': {
    'video': {'videoSn': 33254, 'animeSn': anime},
    'anime': {
      'animeSn': anime,
      'acgSn': acg,
      'title': '百合是我的工作！ [1]',
      'totalEpisode': total,
      'episodes': {
        '0':
            episodes ??
            [
              {'episode': 1, 'videoSn': 33254},
              {'episode': 2, 'videoSn': 33320},
            ],
      },
    },
  },
};
Map<String, Object?> _comment({
  int sn = 32603855,
  num time = 25,
  int position = 0,
  String text = '百合',
  String color = '#FDE53D',
}) => {
  'text': text,
  'color': color,
  'size': 1,
  'position': position,
  'time': time,
  'sn': sn,
  'userid': 'public-user',
};
Object _comments(List<Object?> rows, {int? total}) => {
  'data': {'danmu': rows, 'totalCount': total ?? rows.length},
};
Matcher _error(SourceErrorType type) => isA<SourceException>()
    .having((error) => error.type, 'type', type)
    .having((error) => error.sourceId, 'sourceId', GamerDanmakuClient.sourceId);

class _Http extends FakeHttpClient {
  _Http(this.route)
    : super((_) async => throw StateError('Unexpected text I/O'));
  final FutureOr<Object> Function(Uri uri) route;
  final owners = <SourceRequestCancellation?>[];

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
    expect(sourceId, GamerDanmakuClient.sourceId);
    final raw = await route(Uri.parse(url));
    if (raw is SourceByteStream) return raw;
    final bytes = raw is List<int> ? raw : utf8.encode(jsonEncode(raw));
    return SourceByteStream(
      stream: Stream.value(bytes),
      url: url,
      contentLength: bytes.length,
    );
  }
}

class _Bangumi extends BangumiPublicClient {
  _Bangumi(super.http);
  @override
  Future<Map<String, Object?>> subject(
    String id, {
    bool refresh = false,
  }) async => {'id': int.parse(id), 'date': '2023-04-06'};
}

GamerDanmakuClient _client(_Http http) =>
    GamerDanmakuClient(http: http, bangumi: _Bangumi(http));

void main() {
  test(
    'exact pinned ACG mapping resolves distinct anime and video IDs',
    () async {
      final http = _Http((uri) {
        if (uri.host == 'raw.githubusercontent.com') {
          expect(uri.path, contains(GamerDanmakuClient.mappingRevision));
          return _month;
        }
        if (uri.path.endsWith('search.php')) {
          expect(uri.queryParameters['kw'], '百合是我的工作！');
          return _search;
        }
        expect(uri.path, '/anime/v1/video.php');
        expect(uri.queryParameters['videoSn'], '33254');
        return _video();
      });
      final client = _client(http);
      final choices = await client.episodesForSubject('381666');
      expect(choices.map((row) => row.id), ['33254', '33320']);
      expect(
        choices.every((row) => row.provider == DanmakuProviderKind.gamer),
        isTrue,
      );
      expect(choices.map((row) => row.number), [1, 2]);
      expect(http.requests, hasLength(3));
      expect(
        http.requests.every((request) => !request.followRedirects),
        isTrue,
      );
      expect(
        http.requests.every(
          (request) =>
              !request.headers.containsKey('Cookie') &&
              !request.headers.containsKey('Authorization'),
        ),
        isTrue,
      );
      expect(await client.episodesForSubject('381666'), same(choices));
      expect(http.requests, hasLength(3));
    },
  );

  test('only exact ACG IDs match even when title text is identical', () async {
    final http = _Http((uri) {
      if (uri.host == 'raw.githubusercontent.com') return _month;
      if (uri.path.endsWith('search.php')) {
        return {
          'anime': [(_search['anime'] as List).first],
        };
      }
      throw StateError('Must not load an unrelated video');
    });
    expect(await _client(http).episodesForSubject('381666'), isEmpty);
    expect(http.requests.where((r) => r.url.contains('video.php')), isEmpty);
  });

  test(
    'metadata identity mismatch fails rather than choosing wrong series',
    () async {
      final http = _Http((uri) {
        if (uri.host == 'raw.githubusercontent.com') return _month;
        if (uri.path.endsWith('search.php')) return _search;
        return _video(acg: 999);
      });
      await expectLater(
        _client(http).episodesForSubject('381666'),
        throwsA(_error(SourceErrorType.parse)),
      );
    },
  );

  test(
    'manual video URL ignores tracking and fetches fixed official API',
    () async {
      final http = _Http((uri) {
        expect(uri.host, 'api.gamer.com.tw');
        expect(uri.queryParameters, {'videoSn': '33254'});
        return _video();
      });
      final choices = await _client(http).episodes(
        'https://anime.gamer.com.tw/animeVideo.php?sn=33254&next=https://evil.invalid/',
      );
      expect(choices.first.id, '33254');
      expect(http.requests, hasLength(1));
    },
  );

  test(
    'manual animeRef follows only verified same-host typed video redirect',
    () async {
      final http = _Http((uri) {
        if (uri.path == '/animeRef.php') {
          expect(uri.queryParameters['sn'], '113239');
          return SourceByteStream(
            stream: const Stream.empty(),
            url: uri.toString(),
            statusCode: 301,
            headers: {'Location': 'animeVideo.php?sn=33254'},
          );
        }
        return _video();
      });
      final choices = await _client(http)
          .episodes('https://ani.gamer.com.tw/animeRef.php?sn=113239');
      expect(choices, hasLength(2));
      expect(http.requests, hasLength(2));
    },
  );

  test('external redirects and wrong anime identities are rejected', () async {
    for (final target in [
      'https://evil.invalid/animeVideo.php?sn=33254',
      'https://ani.gamer.com.tw/animeRef.php?sn=33254',
    ]) {
      final http = _Http(
        (uri) => SourceByteStream(
          stream: const Stream.empty(),
          url: uri.toString(),
          statusCode: 302,
          headers: {'location': target},
        ),
      );
      await expectLater(
        _client(http)
            .episodes('https://ani.gamer.com.tw/animeRef.php?sn=113239'),
        throwsA(_error(SourceErrorType.parse)),
      );
      expect(http.requests, hasLength(1));
    }
    final http = _Http(
      (uri) => uri.path == '/animeRef.php'
          ? SourceByteStream(
              stream: const Stream.empty(),
              url: uri.toString(),
              statusCode: 301,
              headers: {'location': 'animeVideo.php?sn=33254'},
            )
          : _video(anime: 9),
    );
    await expectLater(
      _client(http).episodes('https://ani.gamer.com.tw/animeRef.php?sn=113239'),
      throwsA(_error(SourceErrorType.parse)),
    );
  });

  test(
    'manual references reject untyped, forged and ambiguous addresses',
    () async {
      final http = _Http((_) => throw StateError('No request permitted'));
      final client = _client(http);
      for (final reference in [
        '33254',
        'http://ani.gamer.com.tw/animeVideo.php?sn=33254',
        'https://ani.gamer.com.tw.evil.invalid/animeVideo.php?sn=33254',
        'https://user@ani.gamer.com.tw/animeVideo.php?sn=33254',
        'https://ani.gamer.com.tw:444/animeVideo.php?sn=33254',
        'https://ani.gamer.com.tw/animeVideo.php?sn=33254&sn=33320',
        'https://ani.gamer.com.tw/animeVideo.php?sn=033254',
        'https://api.gamer.com.tw/anime/v1/video.php?videoSn=33254',
      ]) {
        await expectLater(
          client.episodes(reference),
          throwsA(_error(SourceErrorType.parse)),
        );
      }
      expect(http.requests, isEmpty);
    },
  );

  test(
    'official comment pools, deciseconds, colors and positions decode',
    () async {
      final http = _Http((uri) {
        expect(uri.host, 'api.gamer.com.tw');
        expect(uri.path, '/anime/v1/danmu.php');
        expect(uri.queryParameters, {'videoSn': '33254', 'geo': 'TW,HK'});
        return _comments([
          _comment(sn: 1, time: 30),
          _comment(sn: 2, time: 10, position: 1),
          _comment(sn: 3, time: 20, position: 2),
        ]);
      });
      final client = _client(http);
      final comments = await client.comments(_choice);
      expect(comments.map((row) => row.time), [1, 2, 3]);
      expect(comments.map((row) => row.mode), [5, 4, 1]);
      expect(comments.first.color, 0xFDE53D);
      expect(comments.first.user, 'public-user');
      expect(await client.comments(_choice), same(comments));
      expect(http.requests, hasLength(1));
    },
  );

  test(
    'valid empty is cached while HTTP and application failures throw',
    () async {
      var calls = 0;
      final http = _Http((uri) {
        calls++;
        if (calls == 1) {
          return SourceByteStream(
            stream: const Stream.empty(),
            url: uri.toString(),
            statusCode: 403,
          );
        }
        if (calls == 2) {
          return {
            'error': {
              'code': 400,
              'status': 'INVALID_ARGUMENT',
              'message': '無效的地區',
            },
          };
        }
        return _comments([]);
      });
      final client = _client(http);
      await expectLater(
        client.comments(_choice),
        throwsA(_error(SourceErrorType.auth)),
      );
      await expectLater(
        client.comments(_choice),
        throwsA(_error(SourceErrorType.network)),
      );
      expect(await client.comments(_choice), isEmpty);
      expect(await client.comments(_choice), isEmpty);
      expect(calls, 3);
    },
  );

  test(
    'partial payload, duplicate IDs and oversized envelopes fail closed',
    () async {
      for (final payload in [
        _comments([_comment()], total: 2),
        _comments([_comment(), _comment()]),
        {
          'data': {'danmu': <Object?>[]},
        },
        {
          'data': {'danmu': 'wrong', 'totalCount': 0},
        },
      ]) {
        final http = _Http((_) => payload);
        await expectLater(
          _client(http).comments(_choice),
          throwsA(_error(SourceErrorType.parse)),
        );
      }
      final http = _Http(
        (uri) => SourceByteStream(
          stream: const Stream.empty(),
          url: uri.toString(),
          contentLength: 2 * 1024 * 1024 + 1,
        ),
      );
      await expectLater(
        _client(http).comments(_choice),
        throwsA(_error(SourceErrorType.parse)),
      );
    },
  );

  test(
    'unsafe or unsupported comments are dropped without executing text',
    () async {
      final http = _Http(
        (_) => _comments([
          _comment(sn: 1, text: '<script>literal</script>'),
          _comment(sn: 2, text: '\u0000control'),
          _comment(sn: 3, time: -1),
          _comment(sn: 4, position: 7),
          _comment(sn: 5, color: 'red'),
        ]),
      );
      final comments = await _client(http).comments(_choice);
      expect(comments.map((row) => row.text), ['<script>literal</script>']);
    },
  );

  test('incomplete and duplicate episode catalogues fail', () async {
    for (final payload in [
      _video(total: 3),
      _video(
        episodes: [
          {'episode': 1, 'videoSn': 33254},
          {'episode': 2, 'videoSn': 33254},
        ],
      ),
      _video(
        total: 1,
        episodes: [
          {'episode': 1, 'videoSn': 33320},
        ],
      ),
    ]) {
      final http = _Http((_) => payload);
      await expectLater(
        _client(http)
            .episodes('https://ani.gamer.com.tw/animeVideo.php?sn=33254'),
        throwsA(_error(SourceErrorType.parse)),
      );
    }
  });

  test(
    'cancelled owner prevents request and late responses cannot be cached',
    () async {
      final pending = Completer<Object>();
      final started = Completer<void>();
      final http = _Http((_) {
        started.complete();
        return pending.future;
      });
      final client = _client(http);
      final cancelled = SourceRequestCancellation()..cancel();
      await expectLater(
        cancelled.run(() => client.comments(_choice)),
        throwsA(_error(SourceErrorType.network)),
      );
      expect(http.requests, isEmpty);
      final owner = SourceRequestCancellation();
      final work = owner.run(() => client.comments(_choice));
      final expectation = expectLater(
        work,
        throwsA(_error(SourceErrorType.network)),
      );
      await started.future;
      owner.cancel();
      await expectation;
      expect(http.owners.single!.cancelled, isTrue);
      pending.complete(_comments([_comment()]));
    },
  );
}
