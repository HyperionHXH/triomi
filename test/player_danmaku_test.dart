import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/player/data/danmaku_overlay.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_client.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_models.dart';
import 'package:triomi/features/player/player_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _Source extends ContentSource implements ContentProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'danmaku',
    name: 'test',
    type: MediaType.anime,
    kind: SourceKind.plugin,
    capabilities: {SourceCapability.content},
  );

  @override
  Future<ChapterContent> content(Chapter chapter) async => ChapterContent(
    playSources: const [
      PlaySource(
        name: 'test',
        url: 'https://video.test/manifest',
        mimeType: 'application/vnd.apple.mpegurl',
        omitCookies: true,
        headers: {'Cookie': 'must-not-reach-player', 'User-Agent': 'test'},
      ),
    ],
  );
}

class _Sources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async {
    final source = _Source();
    return SourceRegistrySnapshot(
      entries: [
        SourceEntry(
          descriptor: source.descriptor,
          source: source,
          enabled: true,
        ),
      ],
      failures: const [],
    );
  }
}

class _Client extends HybridDanmakuClient {
  _Client(FakeHttpClient http)
    : super(http: http, bangumi: BangumiPublicClient(http));

  final first = Completer<List<DanmakuComment>>();
  final second = Completer<List<DanmakuComment>>();
  final owners = <SourceRequestCancellation?>[];
  final requested = <String>[];

  List<DanmakuEpisodeChoice> episodes(DanmakuProviderKind kind) => [
    for (var number = 1; number <= 2; number++)
      DanmakuEpisodeChoice(
        provider: kind,
        id: '${kind.name}-$number',
        title: 'episode $number',
        number: number.toDouble(),
      ),
  ];

  @override
  Future<List<DanmakuEpisodeChoice>> animekoEpisodes(String subjectId) async =>
      episodes(DanmakuProviderKind.animeko);

  @override
  Future<List<DanmakuEpisodeChoice>> bilibiliEpisodesForSubject(
    String subjectId,
  ) async => episodes(DanmakuProviderKind.bilibili);

  @override
  Future<List<DanmakuEpisodeChoice>> gamerEpisodesForSubject(
    String subjectId,
  ) async => episodes(DanmakuProviderKind.gamer);

  @override
  Future<List<DanmakuComment>> comments(DanmakuEpisodeChoice episode) {
    requested.add(episode.id);
    owners.add(SourceRequestCancellation.current);
    return episode.number == 1 ? first.future : second.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform three-source sessions cancel stale episodes', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final database = openTestDatabase();
      final http = FakeHttpClient(
        (_) async => throw StateError('No real HTTP in player tests'),
      );
      final client = _Client(http);
      const item = MediaItem(
        sourceId: 'danmaku',
        remoteId: 'show',
        title: 'show',
        type: MediaType.anime,
      );
      const subject = MediaItem(
        sourceId: 'bangumi-anime',
        remoteId: '400602',
        title: 'show',
        type: MediaType.anime,
      );
      const chapters = [
        Chapter(
          sourceId: 'danmaku',
          remoteId: 'ep1',
          title: 'one',
          sortIndex: 0,
          number: 1,
        ),
        Chapter(
          sourceId: 'danmaku',
          remoteId: 'ep2',
          title: 'two',
          sortIndex: 1,
          number: 2,
        ),
      ];
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(http),
          sourcesProvider.overrideWith(_Sources.new),
          hybridDanmakuClientProvider.overrideWithValue(client),
          animeSubjectProvider(item).overrideWith((_) => Stream.value(subject)),
        ],
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final channels = <MethodChannel>[];
      final opens = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['id'];
          final channel = MethodChannel(
            platform == TargetPlatform.iOS
                ? 'triomi/ios-video/$id'
                : 'triomi/native-video/$id',
          );
          channels.add(channel);
          messenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'open' || call.method == 'setUrl') {
              opens.add(Map<Object?, Object?>.from(call.arguments as Map));
            }
            return null;
          });
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
        const MethodChannel('triomi/platform'),
        (call) async => call.method == 'getVideoBrightness' ? 0.5 : true,
      );
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
      }

      Future<void> event(String method, int position) async {
        final done = Completer<void>();
        final values = platform == TargetPlatform.iOS
            ? {
                'positionMs': position,
                'durationMs': 30000,
                'bufferedPositionMs': 15000,
                'playing': true,
              }
            : {
                'position': position,
                'duration': 30000,
                'bufferedPosition': 15000,
                'playing': true,
              };
        await messenger.handlePlatformMessage(
          channels.last.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, values),
          ),
          (_) => done.complete(),
        );
        await done.future;
        await settle();
      }

      DanmakuController overlay() => tester
          .widget<DanmakuOverlay>(find.byType(DanmakuOverlay))
          .controller;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await settle();
        container.dispose();
        await database.close();
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(channel, null);
        }
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        messenger.setMockMethodCallHandler(
          const MethodChannel('triomi/platform'),
          null,
        );
        debugDefaultTargetPlatformOverride = null;
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: PlayerPage(
              args: PlayerArgs(item: item, chapters: chapters, initialIndex: 0),
            ),
          ),
        ),
      );
      await settle();
      await event('prepared', 1000);
      expect(
        client.requested.toSet(),
        {for (final kind in DanmakuProviderKind.values) '${kind.name}-1'},
      );
      final oldOwners = client.owners.toList();
      expect(oldOwners, everyElement(isNotNull));
      expect(opens.last['mimeType'], 'application/vnd.apple.mpegurl');
      expect((opens.last['headers'] as Map).containsKey('Cookie'), isFalse);
      if (platform == TargetPlatform.iOS) {
        expect(opens.last['omitCookies'], isTrue);
      }
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.secondaryTrackValue, 15000);
      await tester.tap(find.byTooltip('下一集'));
      await settle();
      await event('prepared', 1000);
      expect(oldOwners.every((owner) => owner!.cancelled), isTrue);
      expect(
        client.requested.toSet(),
        containsAll({
          for (final kind in DanmakuProviderKind.values) '${kind.name}-2',
        }),
      );
      client.second.complete([
        const DanmakuComment(time: 1.5, text: 'new episode'),
      ]);
      await settle();
      await event('state', 2000);
      expect(
        overlay().active.map((entry) => entry.comment.text),
        contains('new episode'),
      );
      client.first.complete([
        const DanmakuComment(time: 2.1, text: 'stale episode'),
      ]);
      await settle();
      await event('state', 2400);
      expect(
        overlay().active.map((entry) => entry.comment.text),
        isNot(contains('stale episode')),
      );
      await tester.tap(find.byTooltip('关闭弹幕'));
      await settle();
      expect(overlay().enabled, isFalse);
      expect(overlay().active, isEmpty);
      await tester.tap(find.byTooltip('开启弹幕'));
      await settle();
      expect(overlay().enabled, isTrue);
      expect(http.requests, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
