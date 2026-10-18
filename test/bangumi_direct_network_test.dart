import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/schedule/data/bangumi_schedule_client.dart';

import 'fixtures/fake_http_client.dart';

Map<String, Object?> _calendar({String title = '完整放送表'}) => {
  for (var day = 1; day <= 7; day++)
    '$day': [
      for (var index = 0; index < 30; index++)
        {
          'subject': {
            'id': day * 100 + index,
            'name': 'Original',
            'nameCN': '$title $day/$index',
            'info': '12话 / 2026年10月1日 / 原作者',
            'metaTags': ['TV', '日本'],
            'images': {
              'large': 'https://lain.bgm.tv/pic/cover/l/$day-$index.jpg',
            },
            'rating': {'score': 8.1, 'rank': 101, 'total': 234},
          },
        },
    ],
};

void main() {
  test('compact P1 dates require a complete valid date segment, while explicit dates take priority', () async {
    for (final info in ['2026年10月 / 作者', '2026年2月30日 / 作者', '未定']) {
      final body = _calendar();
      final subject = ((body['1'] as List).first as Map)['subject'] as Map;
      subject['info'] = info;
      final http = FakeHttpClient(
        (_) async => SourceResponse(statusCode: 200, body: jsonEncode(body)),
      );
      expect(
        (await BangumiScheduleClient(
          http: http,
        ).fetchWeekly()).first.items.first.airDate,
        isNull,
      );
    }
    final body = _calendar();
    final subject = ((body['1'] as List).first as Map)['subject'] as Map;
    subject.remove('images');
    subject['image'] = 'https://lain.bgm.tv/pic/cover/l/explicit.jpg';
    subject['airtime'] = {'date': '2026-10-02'};
    final http = FakeHttpClient(
      (_) async => SourceResponse(statusCode: 200, body: jsonEncode(body)),
    );
    final entry = (await BangumiScheduleClient(
      http: http,
    ).fetchWeekly()).first.items.first;
    expect(entry.airDate, '2026-10-02');
    expect(entry.coverUrl, 'https://lain.bgm.tv/pic/cover/l/explicit.jpg');
  });

  test('cold calendar selects anonymous public p1 route and retains every day and work', () async {
    final http = FakeHttpClient(
      (_) async =>
          SourceResponse(statusCode: 200, body: jsonEncode(_calendar())),
    );
    final client = BangumiScheduleClient(http: http);
    final days = await client.fetchWeekly();
    expect(http.requests.single.url, 'https://api.kazumi.fyi/p1/calendar');
    expect(
      http.requests.single.headers.keys.map((key) => key.toLowerCase()),
      everyElement(anyOf('user-agent', 'accept')),
    );
    expect(
      days.map((day) => day.weekday),
      orderedEquals([1, 2, 3, 4, 5, 6, 7]),
    );
    expect(days.map((day) => day.items.length), everyElement(30));
    expect(days.first.items.first.title, '完整放送表 1/0');
    expect(
      days.first.items.first.coverUrl,
      'https://lain.bgm.tv/pic/cover/l/1-0.jpg',
    );
    expect(days.first.items.first.airDate, '2026-10-01');
    expect(days.first.items.first.rating, 8.1);
    expect(days.first.items.first.rank, 101);
    expect(days.first.items.first.votes, 234);
    expect(days.first.items.first.url, 'https://bgm.tv/subject/100');
    expect(client.usedFallback, isFalse);
  });

  test('p1 format requires all seven day lists instead of treating an error object as empty success', () async {
    for (final body in [
      {'error': 'denied'},
      {'1': <Object?>[]},
      {..._calendar(), '7': null},
    ]) {
      final http = FakeHttpClient(
        (_) async => SourceResponse(statusCode: 200, body: jsonEncode(body)),
      );
      await expectLater(
        BangumiScheduleClient(http: http).fetchWeekly(),
        throwsA(isA<SourceException>()),
      );
    }
  });

  test('calendar refresh fetches new data rather than an unlabelled cached snapshot', () async {
    var calls = 0;
    final http = FakeHttpClient(
      (_) async => SourceResponse(
        statusCode: 200,
        body: jsonEncode(_calendar(title: '读取 ${++calls}')),
      ),
    );
    final client = BangumiScheduleClient(http: http);
    expect((await client.fetchWeekly()).first.items.first.title, '读取 1 1/0');
    expect((await client.fetchWeekly()).first.items.first.title, '读取 2 1/0');
    expect(http.requests, hasLength(2));
  });

  test('cancelled p1 request discards late response and never starts legacy fallback', () async {
    final pending = Completer<SourceResponse>();
    final http = FakeHttpClient((_) => pending.future);
    final owner = SourceRequestCancellation();
    final client = BangumiScheduleClient(
      http: http,
      fallbackBaseUrl: BangumiScheduleClient.calendarUrl,
    );
    final future = owner.run(client.fetchWeekly);
    final rejected = expectLater(future, throwsA(isA<SourceException>()));
    owner.cancel();
    pending.complete(
      SourceResponse(statusCode: 200, body: jsonEncode(_calendar())),
    );
    await rejected;
    expect(http.requests, hasLength(1));
    expect(http.requests.single.cancellation!.cancelled, isTrue);
    expect(client.usedBaseUrl, isNull);
  });

  test(
    'v0 metadata keeps its compatible anonymous backend and filter shape',
    () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: request.method == 'POST'
              ? jsonEncode({'data': <Object?>[], 'total': 0})
              : jsonEncode({'id': 100, 'name_cn': '公开元数据'}),
        ),
      );
      final client = BangumiPublicClient(http);
      expect((await client.subject('100'))['id'], 100);
      await client.search(filter: const AnimePublicFilter(tags: ['日常']));
      expect(
        http.requests.map((request) => Uri.parse(request.url).host),
        everyElement('api.bgmapi.com'),
      );
      expect(Uri.parse(http.requests.first.url).path, '/v0/subjects/100');
      expect(jsonDecode(http.requests.last.body!)['filter']['tag'], ['日常']);
      expect(
        http.requests
            .expand((request) => request.headers.keys)
            .map((key) => key.toLowerCase()),
        isNot(
          anyOf(
            contains('authorization'),
            contains('cookie'),
            contains('x-appid'),
            contains('x-signature'),
          ),
        ),
      );
    },
  );
}
