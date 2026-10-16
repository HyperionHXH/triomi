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
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/player/player_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class LocalVideo extends DownloadRepository {
  LocalVideo(super.db);
  @override
  Future<String?> localVideoPath(
    String sourceId,
    String chapterRemoteId,
  ) async => 'D:/public-test-video.mp4';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'reconstructed player restores exact chapter time in its native open request',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final db = openTestDatabase();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          downloadRepositoryProvider.overrideWithValue(LocalVideo(db)),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
        ],
      );
      const item = MediaItem(
        sourceId: 'resume',
        remoteId: 'anime',
        title: 'Anime',
        type: MediaType.anime,
      );
      const chapters = [
        Chapter(
          sourceId: 'resume',
          remoteId: 'ep1',
          title: 'Episode 1',
          volumeTitle: 'main',
          sortIndex: 0,
        ),
        Chapter(
          sourceId: 'resume',
          remoteId: 'ep2',
          title: 'Episode 2',
          sortIndex: 1,
          volumeTitle: 'main',
        ),
        Chapter(
          sourceId: 'resume',
          remoteId: 'alt1',
          title: 'Alternate',
          sortIndex: 2,
          volumeTitle: 'alternate',
        ),
      ];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final channels = <MethodChannel>[];
      final opens = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['id'];
          final channel = MethodChannel('triomi/native-video/$id');
          channels.add(channel);
          messenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'setUrl') {
              opens.add(Map<Object?, Object?>.from(call.arguments as Map));
            }
            return null;
          });
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
        const MethodChannel('triomi/platform'),
        (_) async => null,
      );
      Future<void> settle() async {
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      Future<void> event(String method, Map<String, Object?> args) async {
        final delivered = Completer<void>();
        await messenger.handlePlatformMessage(
          channels.last.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, args),
          ),
          (_) => delivered.complete(),
        );
        await delivered.future;
        await settle();
      }

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await settle();
        container.dispose();
        await db.close();
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(channel, null);
        }
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        messenger.setMockMethodCallHandler(
          const MethodChannel('triomi/platform'),
          null,
        );
        await tester.pump(const Duration(seconds: 6));
        debugDefaultTargetPlatformOverride = null;
      });
      final repo = container.read(libraryRepositoryProvider);
      await tester.runAsync(
        () => repo.recordHistory(
          sourceId: item.sourceId,
          remoteId: item.remoteId,
          chapter: chapters.first,
          position: 71,
        ),
      );
      Widget page(int index) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: PlayerPage(
            args: PlayerArgs(
              item: item,
              chapters: chapters,
              initialIndex: index,
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(0));
      await settle();
      expect(opens, isNotEmpty);
      expect(opens.last['startMilliseconds'], 71000);
      await tester.pump(const Duration(seconds: 6));
      final unchanged = await tester.runAsync(
        () => repo.chapterPositionOf(item.sourceId, item.remoteId, 'ep1'),
      );
      expect(
        unchanged,
        71,
        reason: 'preparation must not overwrite progress with zero',
      );
      await event('prepared', {
        'position': 71000,
        'duration': 120000,
        'playing': true,
      });
      await event('completed', {
        'position': 120000,
        'duration': 120000,
        'playing': false,
      });
      expect(find.textContaining('Episode 2'), findsWidgets);
      expect(
        await tester.runAsync(
          () => repo.chapterPositionOf(item.sourceId, item.remoteId, 'ep1'),
        ),
        120,
      );
      final opensAtLastEpisode = opens.length;
      await event('prepared', {
        'position': 0,
        'duration': 100000,
        'playing': true,
      });
      await event('completed', {
        'position': 100000,
        'duration': 100000,
        'playing': false,
      });
      expect(opens.length, opensAtLastEpisode, reason: '末集不得自动串入另一播放列表');
      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pumpWidget(page(2));
      await settle();
      expect(
        opens.last['startMilliseconds'],
        0,
        reason: 'another episode must not inherit time',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settle();
      await container.read(preferencesProvider).set('privacy.incognito', true);
      await tester.pumpWidget(page(0));
      await settle();
      await event('prepared', {
        'position': 120000,
        'duration': 180000,
        'playing': true,
      });
      await event('state', {
        'position': 150000,
        'duration': 180000,
        'playing': true,
      });
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox());
      await settle();
      expect(
        await tester.runAsync(
          () => repo.chapterPositionOf(item.sourceId, item.remoteId, 'ep1'),
        ),
        120,
        reason: '无痕播放和退出不能覆盖已有播放位置',
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
