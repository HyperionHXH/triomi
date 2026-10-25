import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/novel/data/lk/lk_client.dart';
import 'package:triomi/features/novel/data/lns/lns_auth.dart';
import 'package:triomi/features/novel/data/lns/lns_gateway.dart';
import 'package:triomi/features/novel/data/lns/lns_hub_connection.dart';
import 'package:triomi/features/novel/data/lns/lns_source.dart';
import 'package:triomi/features/novel/novel_list_metadata.dart';

import 'fixtures/fake_http_client.dart';

class _Hub implements LnsHubConnection {
  _Hub(this.handle);
  final Future<Object?> Function(String, Object?) handle;
  @override
  Future<Object?> invoke(String target, Object? params) async => {
    'Success': true,
    'Response': await handle(target, params),
  };
  @override
  void reset() {}
}

class _Sources extends SourceRegistryController {
  _Sources(this.source);
  final LnsSource source;
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      SourceEntry(descriptor: source.descriptor, source: source, enabled: true),
    ],
    failures: const [],
  );
}

LnsSource _source(_Hub hub, {DateTime Function()? clock}) {
  final limiter = ShelfRateLimiter(maxRequests: 10000);
  return LnsSource(
    metadataClock: clock,
    gateway: LnsGateway(connection: hub, limiter: limiter),
    auth: LnsAuth(
      http: FakeHttpClient((_) async => throw StateError('No account network')),
      limiter: limiter,
      store: SecureLnsTokenStore(MemorySecureStore()),
    ),
  );
}

MediaItem _item(String id, {String? author, String? description}) => MediaItem(
  sourceId: LnsSource.id,
  remoteId: id,
  type: MediaType.novel,
  title: 'List title $id',
  coverUrl: 'https://cover.test/$id',
  author: author,
  description: description,
  tags: const ['List tag'],
  status: 'List status',
);

Map<String, Object?> _detail(
  int id, {
  String author = 'Actual author',
  String summary = 'Detail summary',
}) => {
  'Id': id,
  'Title': 'Detail title',
  'Author': author,
  'UserName': 'Uploader',
  'Introduction': summary,
  'Chapters': [
    {'Id': id * 100, 'Title': 'Chapter', 'SortNum': 1},
  ],
};

void main() {
  test(
    'LK keeps coin, nested level name/id and only real nonnegative experience',
    () {
      final profile = LkClient.parseAccountProfile({
        'profile': {
          'uid': 1,
          'coin': 128,
          'level': {'id': 3, 'name': '勋爵'},
          'exp': '42',
        },
      });
      expect(profile.coin, 128);
      expect(profile.level, 3);
      expect(profile.levelName, '勋爵');
      expect(profile.experience, 42);
      expect(LkClient.parseAccountProfile({'exp': -1}).experience, isNull);
      expect(LkClient.parseAccountProfile({}).experience, isNull);
      expect(LkClient.parseAccountProfile({'exp': 0}).experience, 0);
    },
  );

  test('LNS search quotes title/author queries once and never mistakes uploader for author', () async {
    final queries = <Object?>[];
    final source = _source(
      _Hub((target, params) async {
        expect(target, 'GetBookList');
        queries.add((params as Map)['KeyWords']);
        return {
          'Page': 1,
          'TotalPages': 1,
          'Data': [
            {'Id': 1, 'Title': 'Uploader only', 'UserName': 'Not author'},
            {
              'Id': 2,
              'Title': 'Real author',
              'UserName': 'Uploader',
              'Author': 'Author',
            },
            {
              'Id': 3,
              'Title': 'Class author',
              'Extra': {
                'Classification': {'Author': 'Class author'},
              },
            },
          ],
        };
      }),
    );
    final books = await source.search(' Author name ');
    await source.search('"Already quoted"', page: 2);
    expect(queries, ['"Author name"', '"Already quoted"']);
    expect(books.map((book) => book.author), [null, 'Author', 'Class author']);
  });

  test('detail and directory coalesce, expire and clear without caching download permission reads', () async {
    var now = DateTime.utc(2026, 10, 22);
    var reads = 0;
    final pending = Completer<Object?>();
    final source = _source(
      _Hub((target, params) async {
        expect(target, 'GetBookInfo');
        reads++;
        if (reads == 1) return pending.future;
        return _detail(1);
      }),
      clock: () => now,
    );
    final detail = source.detail(_item('1'));
    final chapters = source.chapters(_item('1'));
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    pending.complete(_detail(1));
    expect((await detail).author, 'Actual author');
    expect(await chapters, hasLength(1));
    await source.detail(_item('1'));
    expect(reads, 1);
    await source.officialDownloadPermission(_item('1'));
    expect(reads, 2);
    now = now.add(const Duration(minutes: 6));
    await source.detail(_item('1'));
    expect(reads, 3);
    source.clearMetadataCache();
    await source.detail(_item('1'));
    expect(reads, 4);
  });

  test('metadata cache has an LRU count/weight bound and rejects stale in-flight publication', () async {
    var reads = 0;
    final source = _source(
      _Hub((target, params) async {
        reads++;
        return _detail((params as Map)['Id'] as int);
      }),
    );
    for (var id = 1; id <= 65; id++) {
      await source.detail(_item('$id'));
    }
    await source.detail(_item('1'));
    expect(reads, 66);
    var oversizedReads = 0;
    final oversized = _source(
      _Hub((_, _) async {
        oversizedReads++;
        return _detail(1, summary: ''.padRight(512 * 1024 + 1, 'x'));
      }),
    );
    await oversized.detail(_item('1'));
    await oversized.detail(_item('1'));
    expect(oversizedReads, 2);

    final gate = Completer<Object?>();
    final stale = _source(_Hub((_, _) => gate.future));
    final result = stale.detail(_item('1'));
    final rejection = expectLater(result, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    stale.clearMetadataCache();
    gate.complete(_detail(1));
    await rejection;
  });

  test('metadata hydration fills only missing author/summary and leaves card identity/state intact', () async {
    final source = _source(_Hub((_, _) async => _detail(1)));
    final original = _item('1');
    final hydrated = await source.listMetadata(original);
    expect(hydrated.author, 'Actual author');
    expect(hydrated.description, 'Detail summary');
    expect(hydrated.title, original.title);
    expect(hydrated.coverUrl, original.coverUrl);
    expect(hydrated.tags, original.tags);
    expect(hydrated.status, original.status);
    final populated = await source.listMetadata(
      _item('1', author: 'List author', description: 'List summary'),
    );
    expect(populated.author, 'List author');
    expect(populated.description, 'List summary');
  });

  testWidgets(
    'metadata consumer shows list immediately then progressive real author',
    (tester) async {
      final pending = Completer<Object?>();
      final source = _source(_Hub((_, _) => pending.future));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sourcesProvider.overrideWith(() => _Sources(source))],
          child: MaterialApp(
            home: NovelListMetadata(
              item: _item('1'),
              builder: (item) => Text('${item.title}|${item.author ?? ''}'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('List title 1|'), findsOneWidget);
      pending.complete(_detail(1));
      await tester.pumpAndSettle();
      expect(find.text('List title 1|Actual author'), findsOneWidget);
    },
  );

  testWidgets(
    'metadata failure retains list card and offers an independent retry',
    (tester) async {
      var reads = 0;
      final source = _source(
        _Hub((_, _) async {
          if (++reads == 1) throw StateError('Metadata offline');
          return _detail(1);
        }),
      );
      final item = _item('1');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sourcesProvider.overrideWith(() => _Sources(source))],
          child: MaterialApp(
            home: NovelListMetadata(
              item: item,
              builder: (item) => Text('${item.title}|${item.author ?? ''}'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('List title 1|'), findsOneWidget);
      await tester.tap(find.textContaining('书籍信息补全失败，重试'));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text('List title 1|Actual author'), findsOneWidget);
    },
  );

  test('LNS growth distinguishes access/growth levels, missing thresholds and explicit max', () async {
    Map<String, Object?> growth = {
      'Coin': 128,
      'Level': '2',
      'GrowthLevel': '4',
      'Exp': '150',
      'CurrentLevelExp': '100',
      'NextLevelExp': '300',
    };
    final source = _source(_Hub((_, _) async => {'Id': 1, 'Growth': growth}));
    var profile = await source.profile();
    expect(profile.level, 2);
    expect(profile.growthLevel, 4);
    expect(profile.experienceFraction, .25);
    growth = {'Exp': 150};
    profile = await source.profile();
    expect(profile.maxLevel, isFalse);
    expect(profile.experienceFraction, isNull);
    growth = {'Exp': 150, 'NextLevelExp': null};
    profile = await source.profile();
    expect(profile.maxLevel, isTrue);
    expect(profile.experienceFraction, 1);
    growth = {'Exp': -1, 'GrowthLevel': -2};
    profile = await source.profile();
    expect(profile.experience, isNull);
    expect(profile.growthLevel, isNull);
  });

  test('sign-in reads authoritative balance/experience deltas instead of SignIn.Reward', () async {
    var signed = false;
    final source = _source(
      _Hub((target, _) async {
        if (target == 'SignIn') {
          signed = true;
          return {'Reward': 9999, 'Streak': 4};
        }
        return {
          'Id': 1,
          'Growth': {
            'Coin': signed ? 148 : 128,
            'Exp': signed ? 160 : 150,
            'SignStreak': signed ? 4 : 3,
            'TodaySigned': signed,
          },
        };
      }),
    );
    final result = await source.claimSign();
    expect(result.reward, 20);
    expect(result.experienceReward, 10);
    expect(result.profile!.coin, 148);
    expect(result.streak, 4);
  });

  test('successful sign-in followed by profile failure has unknown rewards, not fake zero/failure', () async {
    var signed = false;
    final source = _source(
      _Hub((target, _) async {
        if (target == 'SignIn') {
          signed = true;
          return {'Reward': 9999, 'Streak': 4};
        }
        if (signed) throw StateError('Profile unavailable');
        return {
          'Id': 1,
          'Growth': {'Coin': 128, 'Exp': 150},
        };
      }),
    );
    final result = await source.claimSign();
    expect(result.reward, isNull);
    expect(result.experienceReward, isNull);
    expect(result.profile, isNull);
    expect(result.streak, 4);
  });

  test('font payload LRU eviction keeps returned offline payload intact and coalesces loads', () async {
    var reads = 0;
    final http = FakeHttpClient(
      (_) async => const SourceResponse(statusCode: 200, body: ''),
    );
    http.bytesHandler = (_) {
      reads++;
      return [0, 1, 0, 0, 1, 2, 3, 4];
    };
    final channel = LnsFontChannel(
      http: http,
      maxCacheBytes: 100,
      registerFont: (_) async => 'family',
    );
    final first = await channel.load('/font/a.ttf');
    await channel.load('/font/b.ttf');
    expect(first.family, 'family');
    expect(first.data, 'AAEAAAECAwQ=');
    await channel.load('/font/a.ttf');
    expect(reads, 3);
    channel.clearTemporaryData();
    await Future.wait([
      channel.load('/font/a.ttf'),
      channel.load('/font/a.ttf'),
    ]);
    expect(reads, 4);
    expect(first.data, 'AAEAAAECAwQ=');
  });
}
