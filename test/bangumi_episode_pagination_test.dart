import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/http_client.dart';

import 'fixtures/fake_http_client.dart';

void main() {
  Map<String, Object?> episode(int id) => {'id': id, 'sort': id, 'type': 0};
  SourceResponse response(Object value) =>
      SourceResponse(statusCode: 200, body: jsonEncode(value));

  test('complete episode read preserves specials beyond first page', () async {
    final client = BangumiPublicClient(
      FakeHttpClient((request) async {
        final offset = int.parse(
          Uri.parse(request.url).queryParameters['offset']!,
        );
        return response({
          'total': 101,
          'data': offset == 0
              ? List.generate(100, (i) => episode(i + 1))
              : [
                  {...episode(101), 'type': 1},
                ],
        });
      }),
    );
    final episodes = await client.allEpisodes('42');
    expect(
      episodes.map((row) => row['id']).toList(),
      List.generate(101, (i) => i + 1),
    );
    expect(episodes.last['type'], 1);
  });

  for (final invalid in <Object>[10001, -1, 2.5, '100']) {
    test(
      'invalid episode total $invalid fails instead of requesting unbounded pages',
      () async {
        final http = FakeHttpClient(
          (request) async => response({
            'total': invalid,
            'data': [episode(1)],
          }),
        );
        await expectLater(
          BangumiPublicClient(http).allEpisodes('42'),
          throwsFormatException,
        );
        expect(http.requests.length, 1);
      },
    );
  }

  test(
    'repeated page identities reject incomplete episode snapshots',
    () async {
      final http = FakeHttpClient(
        (request) async => response({
          'total': 200,
          'data': List.generate(100, (i) => episode(i + 1)),
        }),
      );
      await expectLater(
        BangumiPublicClient(http).allEpisodes('42'),
        throwsFormatException,
      );
      expect(http.requests.length, 2);
    },
  );

  test('changing remote total cannot publish a truncated snapshot', () async {
    final http = FakeHttpClient((request) async {
      final first = Uri.parse(request.url).queryParameters['offset'] == '0';
      return response({
        'total': first ? 101 : 102,
        'data': first
            ? List.generate(100, (i) => episode(i + 1))
            : [episode(101)],
      });
    });
    await expectLater(
      BangumiPublicClient(http).allEpisodes('42'),
      throwsFormatException,
    );
  });
}
