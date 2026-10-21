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
import 'package:triomi/features/player/data/player_settings.dart';
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
      final nativeCalls = <MethodCall>[];
      Completer<void>? pendingPause;
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['id'];
          final channel = MethodChannel('triomi/native-video/$id');
          channels.add(channel);
          messenger.setMockMethodCallHandler(channel, (call) async {
            nativeCalls.add(call);
            if (call.method == 'pause') await pendingPause?.future;
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

      // Danmaku keeps scheduling frames during playback. Wait for route
      // transitions without requiring the entire player to become idle.
      Future<void> settleRoute() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
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
        await tester.binding.setSurfaceSize(null);
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
      // The selected label must update even if pausing the old, unprepared
      // native player has not answered yet.
      final pause = Completer<void>();
      pendingPause = pause;
      final opensBeforeSelection = opens.length;
      await tester.tap(find.byTooltip('剧集'));
      await settleRoute();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Episode 2'));
      await tester.pump();
      expect(opens.length, opensBeforeSelection);
      pause.complete();
      pendingPause = null;
      await settle();
      await settleRoute();
      expect(opens.last['title'], contains('Episode 2'));
      await tester.tap(find.byTooltip('剧集'));
      await settleRoute();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Episode 1'));
      await settle();
      await settleRoute();
      expect(opens.last['startMilliseconds'], 71000);
      await event('prepared', {
        'position': 71000,
        'duration': 120000,
        'playing': true,
      });
      final previous = find.widgetWithIcon(
        IconButton,
        Icons.skip_previous_rounded,
      );
      final next = find.widgetWithIcon(IconButton, Icons.skip_next_rounded);
      expect(tester.widget<IconButton>(previous).onPressed, isNull);
      expect(tester.widget<IconButton>(next).onPressed, isNotNull);
      final playbackOpens = opens.length;
      final playbackViews = channels.length;
      for (final size in [
        const Size(280, 640),
        const Size(320, 700),
        const Size(720, 400),
        const Size(1280, 800),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pump();
        expect(channels.length, playbackViews,
            reason: 'rotation/resizing must retain the playing native surface');
        expect(opens.length, playbackOpens,
            reason: 'rotation/resizing must not reload or seek the media');
      }
      await tester.binding.setSurfaceSize(const Size(320, 700));
      await tester.pump();
      int getSeekTarget() => (nativeCalls.lastWhere(
        (call) => call.method == 'seek',
      ).arguments as Map)['milliseconds'] as int;
      final seeksBeforeTap = nativeCalls.where((call) => call.method == 'seek').length;
      final surface = find.byType(PlatformViewLink);
      final surfaceRect = tester.getRect(surface);
      final leftPoint = Offset(
        surfaceRect.left + surfaceRect.width * .125, surfaceRect.center.dy,
      );
      final rightPoint = Offset(
        surfaceRect.left + surfaceRect.width * .875, surfaceRect.center.dy,
      );
      Future<void> doubleTapAt(Offset point) async {
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 350));
      }
      await tester.tapAt(leftPoint);
      await tester.pump(const Duration(milliseconds: 350));
      expect(nativeCalls.where((call) => call.method == 'seek').length, seeksBeforeTap,
          reason: 'a single tap at the edge must not change playback position');
      await doubleTapAt(leftPoint);
      expect(getSeekTarget(), 56000);
      await event('state', {
        'position': 71000, 'duration': 120000, 'playing': true,
      });
      await doubleTapAt(rightPoint);
      expect(getSeekTarget(), 86000);
      await event('state', {
        'position': 5000, 'duration': 120000, 'playing': true,
      });
      await doubleTapAt(leftPoint);
      expect(getSeekTarget(), 0, reason: 'seeking before the start clamps to zero');
      await event('state', {
        'position': 115000, 'duration': 120000, 'playing': true,
      });
      await doubleTapAt(rightPoint);
      expect(getSeekTarget(), 120000,
          reason: 'seeking past the end never opens another episode');
      expect(opens.length, playbackOpens);
      await event('state', {
        'position': 71000, 'duration': 120000, 'playing': true,
      });
      await tester.tap(find.byKey(const ValueKey('player-skip')));
      await tester.pump();
      expect(getSeekTarget(), 120000, reason: '80-second skip also clamps to duration');
      await tester.longPress(find.byKey(const ValueKey('player-skip')));
      await settleRoute();
      await tester.enterText(find.byType(TextFormField), '30');
      await tester.tap(find.text('保存'));
      await settleRoute();
      expect(PlayerSettings.load(container.read(preferencesProvider)).skipSeconds, 30);
      await event('state', {
        'position': 71000, 'duration': 120000, 'playing': true,
      });
      await tester.tap(find.byKey(const ValueKey('player-skip')));
      await tester.pump();
      expect(getSeekTarget(), 101000);
      await event('state', {
        'position': 71000, 'duration': 120000, 'playing': true,
      });
      await doubleTapAt(rightPoint);
      expect(getSeekTarget(), 86000,
          reason: 'configured skip must not change the edge double-tap interval');
      // Between one quarter and one third belongs to the center, not the edge.
      await doubleTapAt(Offset(
        surfaceRect.left + surfaceRect.width * .28, surfaceRect.center.dy,
      ));
      expect(nativeCalls.last.method, 'pause');
      await event('state', {
        'position': 71000, 'duration': 120000, 'playing': false,
      });
      // A preview is not played progress: the timer must not persist it, and
      // cancellation must leave both the decoder and the stored resume intact.
      await tester.pump(const Duration(seconds: 6));
      await settle();
      final storedBeforePreview = await tester.runAsync(
        () => repo.chapterPositionOf(item.sourceId, item.remoteId, 'ep1'),
      );
      expect(storedBeforePreview, 71);
      final seekCountBeforePreview =
          nativeCalls.where((call) => call.method == 'seek').length;
      final preview = await tester.startGesture(surfaceRect.center);
      await preview.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(find.byKey(const ValueKey('player-seek-hud')), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await settle();
      expect(
        await tester.runAsync(
          () => repo.chapterPositionOf(item.sourceId, item.remoteId, 'ep1'),
        ),
        storedBeforePreview,
        reason: 'uncommitted video drag must not overwrite stored resume',
      );
      await preview.cancel();
      await tester.pump(const Duration(seconds: 6));
      await settle();
      expect(
        await tester.runAsync(
          () => repo.chapterPositionOf(item.sourceId, item.remoteId, 'ep1'),
        ),
        storedBeforePreview,
        reason: 'cancelled preview must persist the original played position',
      );
      expect(
        nativeCalls.where((call) => call.method == 'seek').length,
        seekCountBeforePreview,
      );
      expect(opens.length, playbackOpens);
      expect(channels.length, playbackViews);
      await tester.drag(find.byType(Slider), const Offset(30, 0));
      await tester.pump();
      expect(nativeCalls.any((call) => call.method == 'seek'), isTrue);
      await tester.tap(find.byTooltip('播放设置'));
      await settleRoute();
      await tester.tap(find.text('字幕'));
      await settleRoute();
      await tester.tap(find.text('关闭字幕'));
      await settleRoute();
      expect(
        nativeCalls.any((call) => call.method == 'selectSubtitle'),
        isTrue,
      );
      await tester.tap(find.byTooltip('倍速 · 1.0x'));
      await settleRoute();
      expect(find.text('1.5x'), findsOneWidget);
      await tester.tap(find.text('1.5x'));
      await settleRoute();
      expect(
        nativeCalls.any(
          (call) =>
              call.method == 'setRate' &&
              (call.arguments as Map)['rate'] == 1.5,
        ),
        isTrue,
      );
      await tester.tap(find.byTooltip('全屏'));
      await tester.binding.setSurfaceSize(const Size(720, 320));
      await settleRoute();
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      await tester.tap(find.byTooltip('视频比例'));
      await settleRoute();
      await tester.ensureVisible(find.text('16:10'));
      await tester.tap(find.text('16:10'));
      await settleRoute();
      expect(PlayerSettings.load(container.read(preferencesProvider)).aspectRatio,
          VideoAspectRatio.ratio16x10);
      final videoFrame = tester.getSize(find.byType(AndroidViewSurface));
      expect(videoFrame.width / videoFrame.height, closeTo(1.6, .001),
          reason: 'forced aspect must constrain the actual native surface');
      expect(channels.length, playbackViews,
          reason: 'aspect changes must retain the active native view');
      expect(opens.length, playbackOpens,
          reason: 'aspect changes must not reload media');
      await tester.tap(find.byTooltip('退出全屏'));
      await tester.binding.setSurfaceSize(null);
      await settleRoute();
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
      expect(
        tester.widget<IconButton>(next).onPressed,
        isNull,
        reason: 'manual next must also stop at the playlist boundary',
      );
      expect(tester.widget<IconButton>(previous).onPressed, isNotNull);
      await event('completed', {
        'position': 100000,
        'duration': 100000,
        'playing': false,
      });
      expect(opens.length, opensAtLastEpisode, reason: '末集不得自动串入另一播放列表');
      await tester.tap(previous);
      await settle();
      await event('prepared', {
        'position': 120000,
        'duration': 180000,
        'playing': true,
      });
      expect(opens.last['title'], contains('Episode 1'));
      await tester.tap(next);
      await settle();
      await event('prepared', {
        'position': 100000,
        'duration': 180000,
        'playing': true,
      });
      expect(opens.last['title'], contains('Episode 2'));
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
        150,
        reason: '正常播放和退出持续保存实际播放位置',
      );
      final openCount = opens.length;
      await tester.pumpWidget(page(-1));
      await settle();
      expect(opens.length, openCount, reason: '无效的未选剧集不得自动播放第一集');
      expect(find.text('尚未选择有效的本站剧集'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pumpWidget(page(0));
      await settle();
      await tester.pump(const Duration(seconds: 31));
      expect(find.textContaining('视频准备超时'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget,
          reason: 'failure must retain an immediately usable exit');
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
