import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/anime/data/anime_collection_service.dart';
import 'package:triomi/features/tracking/data/bangumi_client.dart';

import 'fixtures/fake_http_client.dart';

const firstSeason = MediaItem(sourceId: 'bangumi-anime', remoteId: '12',
  type: MediaType.anime, title: '相同标题');
const secondSeason = MediaItem(sourceId: 'bangumi-anime', remoteId: '13',
  type: MediaType.anime, title: '相同标题');

SourceResponse jsonResponse(Object body) => SourceResponse(statusCode: 200, body: jsonEncode(body));
Map<String, Object?> collection(int id, int type) => {
  'subject_id': id, 'type': type, 'ep_status': 4,
  'updated_at': '2026-10-17T10:00:00Z',
  'subject': {'id': id, 'type': 2, 'name_cn': '动画$id'},
};
AnimeCollectionService serviceFor(FakeHttpClient http, {String? Function()? token}) =>
  AnimeCollectionService(client: BangumiClient(http: http, baseUrl: 'https://bgm.test'),
    token: token ?? () => 'fixture-token', canonical: (item) async => item);

void main() {
  test('authenticated anime collections paginate atomically and retain five states', () async {
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      if (uri.path == '/v0/me') return jsonResponse({'id': 99, 'username': 'account', 'nickname': '昵称'});
      expect(uri.path, '/v0/users/99/collections');
      expect(uri.queryParameters['subject_type'], '2');
      final offset = int.parse(uri.queryParameters['offset']!);
      return jsonResponse({'total': 5, 'data': [collection(12 + offset, offset + 1)]});
    });
    final snapshot = await serviceFor(http).load();
    expect(snapshot.account, '昵称');
    expect(snapshot.entries.map((row) => row.status), ['want', 'done', 'doing', 'paused', 'dropped']);
    expect(snapshot.entries.map((row) => row.item.remoteId), ['12', '13', '14', '15', '16']);
    expect(http.requests.every((r) => r.headers['Authorization'] == 'Bearer fixture-token'), isTrue);
  });

  test('failed later page cannot publish a partial collection', () async {
    final http = FakeHttpClient((request) async {
      if (request.url.endsWith('/v0/me')) return jsonResponse({'id': 99});
      if (Uri.parse(request.url).queryParameters['offset'] == '0') {
        return jsonResponse({'total': 2, 'data': [collection(12, 3)]});
      }
      return const SourceResponse(statusCode: 503, body: 'service unavailable');
    });
    await expectLater(serviceFor(http).load(), throwsA(isA<SourceException>()));
  });

  test('status writes preserve season id and failed requests remain retryable', () async {
    var fail = true;
    final http = FakeHttpClient((request) async {
      if (fail) return const SourceResponse(statusCode: 403, body: 'denied');
      return const SourceResponse(statusCode: 202, body: '');
    });
    final service = serviceFor(http);
    await expectLater(service.updateStatus(firstSeason, 'doing'), throwsA(isA<SourceException>()));
    fail = false;
    await service.updateStatus(secondSeason, 'done');
    expect(http.requests.last.url, 'https://bgm.test/v0/users/-/collections/13');
    expect(jsonDecode(http.requests.last.body!), {'type': 2});
    expect(http.requests.first.url, endsWith('/12'));
  });

  test('missing account and unbound site identity never write', () async {
    final http = FakeHttpClient((_) async => const SourceResponse(statusCode: 202, body: ''));
    await expectLater(serviceFor(http, token: () => null).status(firstSeason), throwsStateError);
    await expectLater(serviceFor(http).updateStatus(const MediaItem(
      sourceId: 'streaming-site', remoteId: '12', type: MediaType.anime, title: '相同标题'), 'doing'), throwsStateError);
    expect(http.requests, isEmpty);
  });

  test('account switch during queued writes never applies the next write to new account', () async {
    var token = 'account-a';
    final gate = Completer<SourceResponse>();
    final started = Completer<void>();
    final http = FakeHttpClient((_) { started.complete(); return gate.future; });
    final service = serviceFor(http, token: () => token);
    final first = service.updateStatus(firstSeason, 'doing');
    final next = service.updateStatus(secondSeason, 'want');
    final checks = [expectLater(first, throwsStateError), expectLater(next, throwsStateError)];
    await started.future;
    token = 'account-b';
    gate.complete(const SourceResponse(statusCode: 202, body: ''));
    await Future.wait(checks);
    expect(http.requests, hasLength(1));
    expect(http.requests.single.headers['Authorization'], 'Bearer account-a');
    await expectLater(service.status(firstSeason), throwsStateError);
  });

  test('disposed reads cannot return old account collection', () async {
    final gate = Completer<SourceResponse>();
    final http = FakeHttpClient((_) => gate.future);
    final service = serviceFor(http);
    final loading = service.load();
    final check = expectLater(loading, throwsStateError);
    service.dispose();
    gate.complete(jsonResponse({'id': 99}));
    await check;
    expect(http.requests, hasLength(1));
  });


  test('reused Bangumi client never reuses previous account uid after token switch', () async {
    final http = FakeHttpClient((request) async {
      final account = request.headers['Authorization'] == 'Bearer a' ? 11 : 22;
      if (request.url.endsWith('/v0/me')) return jsonResponse({'id': account});
      expect(Uri.parse(request.url).path, '/v0/users/$account/collections/12');
      return jsonResponse({'subject_id': 12, 'type': 3});
    });
    final client = BangumiClient(http: http, baseUrl: 'https://bgm.test');
    await client.collection(12, token: 'a');
    await client.collection(12, token: 'b');
    expect(http.requests.where((request) => request.url.endsWith('/v0/me')), hasLength(2));
  });

  test('empty, null and unknown remote statuses are errors, not fabricated watching', () async {
    for (final body in ['', 'null', '{"type":99}', '{"subject_id":13,"type":3}']) {
      final http = FakeHttpClient((request) async => request.url.endsWith('/v0/me')
        ? jsonResponse({'id': 99}) : SourceResponse(statusCode: 200, body: body));
      await expectLater(serviceFor(http).status(firstSeason), throwsA(isA<SourceException>()));
    }
  });


  test('account authentication and parse failures cannot turn into not-collected', () async {
    for (final response in [
      const SourceResponse(statusCode: 401, body: ''),
      const SourceResponse(statusCode: 403, body: ''),
      const SourceResponse(statusCode: 200, body: ''),
      jsonResponse({'id': 0}),
    ]) {
      final http = FakeHttpClient((request) async => request.url.endsWith('/v0/me')
        ? response : const SourceResponse(statusCode: 404, body: ''));
      await expectLater(serviceFor(http).status(firstSeason), throwsA(isA<SourceException>()));
      expect(http.requests, hasLength(1));
    }
  });

  test('a failed account lookup is retried instead of caching an anonymous read path', () async {
    var attempts = 0;
    final http = FakeHttpClient((request) async {
      if (request.url.endsWith('/v0/me')) {
        if (attempts++ == 0) return const SourceResponse(statusCode: 503, body: '');
        return jsonResponse({'id': 99});
      }
      if (request.url.contains('/users/-/')) {
        return const SourceResponse(statusCode: 503, body: '');
      }
      expect(request.url, contains('/users/99/'));
      return jsonResponse({'subject_id': 12, 'type': 3});
    });
    final service = serviceFor(http);
    await expectLater(service.status(firstSeason), throwsA(isA<SourceException>()));
    expect((await service.status(firstSeason))!.localStatus, 'doing');
    expect(attempts, 2);
  });

  test('changing pagination total cannot publish a truncated account snapshot', () async {
    final service = serviceFor(FakeHttpClient((request) async {
      if (request.url.endsWith('/v0/me')) return jsonResponse({'id': 99});
      return Uri.parse(request.url).queryParameters['offset'] == '0'
        ? jsonResponse({'total': 3, 'data': [collection(12, 3)]})
        : jsonResponse({'total': 2, 'data': [collection(13, 3)]});
    }));
    await expectLater(service.load(), throwsStateError);
  });

  test('review edits patch only review fields and retain canonical season and existing state', () async {
    var written = false;
    final http = FakeHttpClient((request) async {
      if (request.url.endsWith('/v0/me')) return jsonResponse({'id': 99});
      if (request.method == 'GET') {
        expect(request.url, 'https://bgm.test/v0/users/99/collections/13');
        return jsonResponse({...collection(13, 4), 'rate': written ? 0 : 9,
          'comment': written ? '' : '原短评', 'private': true, 'tags': ['保留标签']});
      }
      expect(request.method, 'PATCH');
      expect(request.url, 'https://bgm.test/v0/users/-/collections/13');
      expect(jsonDecode(request.body!), {'rate': 0, 'comment': '', 'private': true});
      written = true;
      return const SourceResponse(statusCode: 204, body: '');
    });
    final service = serviceFor(http);
    final previous = (await service.status(secondSeason))!;
    expect(previous.comment, '原短评');
    expect(previous.private, isTrue);
    final edited = await service.updateReview(secondSeason, rate: 0,
      comment: '', private: previous.private, newStatus: 'doing');
    expect(edited.type, 4);
    expect(edited.epStatus, 4);
    expect(edited.rate, 0);
    expect(edited.comment, '');
  });

  test('first review creates only explicitly chosen collection status', () async {
    var written = false;
    final http = FakeHttpClient((request) async {
      if (request.url.endsWith('/v0/me')) return jsonResponse({'id': 99});
      if (request.method == 'GET') {
        return written
          ? jsonResponse({...collection(12, 1), 'rate': 7, 'comment': '新短评', 'private': false})
          : const SourceResponse(statusCode: 404, body: '{}');
      }
      expect(request.method, 'POST');
      expect(jsonDecode(request.body!), {'type': 1, 'rate': 7,
        'comment': '新短评', 'private': false});
      written = true;
      return const SourceResponse(statusCode: 202, body: '');
    });
    final result = await serviceFor(http).updateReview(firstSeason,
      rate: 7, comment: '新短评', private: false, newStatus: 'want');
    expect(result.type, 1);
  });

  test('account change while reading review prevents any review write', () async {
    var token = 'first-account';
    final response = Completer<SourceResponse>();
    final started = Completer<void>();
    final http = FakeHttpClient((request) async {
      if (request.url.endsWith('/v0/me')) return jsonResponse({'id': 99});
      started.complete();
      return response.future;
    });
    final service = serviceFor(http, token: () => token);
    final saving = service.updateReview(firstSeason, rate: 9,
      comment: '旧账号草稿', private: false, newStatus: 'doing');
    final check = expectLater(saving, throwsStateError);
    await started.future;
    token = 'other-account';
    response.complete(jsonResponse(collection(12, 3)));
    await check;
    expect(http.requests.every((request) => request.method == 'GET'), isTrue);
  });

  test('failed review read never creates a replacement collection', () async {
    final http = FakeHttpClient((request) async => request.url.endsWith('/v0/me')
      ? jsonResponse({'id': 99})
      : const SourceResponse(statusCode: 403, body: '{}'));
    await expectLater(serviceFor(http).updateReview(firstSeason, rate: 9,
      comment: '草稿', private: false, newStatus: 'doing'), throwsA(isA<SourceException>()));
    expect(http.requests.every((request) => request.method == 'GET'), isTrue);
  });

}
