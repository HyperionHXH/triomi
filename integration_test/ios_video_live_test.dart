import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/player/data/danmaku_overlay.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_client.dart';
import 'package:triomi/features/player/player_page.dart';

import '../test/fixtures/fake_preferences.dart';
import 'fixtures/ios_test_binding.dart';
import 'fixtures/ios_tour_fixtures.dart';

class _FixtureSource extends ContentSource implements ContentProvider {
  _FixtureSource(this.url);
  final String url;
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'ios-video-smoke',
    name: 'Loopback video fixture',
    type: MediaType.anime,
    kind: SourceKind.plugin,
    capabilities: {SourceCapability.content},
  );
  @override
  Future<ChapterContent> content(Chapter chapter) async => ChapterContent(
    playSources: [PlaySource(name: 'fixture', url: url)],
  );
}

class _FixtureRegistry extends SourceRegistryController {
  _FixtureRegistry(this.source);
  final _FixtureSource source;
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      SourceEntry(descriptor: source.descriptor, source: source, enabled: true),
    ],
    failures: const [],
  );
}

/// Uses production PlayerPage and real decoder/network/overlay. No native
/// channel handlers or player state are mocked. Source metadata is a fixture.
void main() {
  initializeIosIntegrationBinding();
  testWidgets(
    'real PlayerPage decodes video and toggles independent danmaku',
    (tester) async {
      const url = String.fromEnvironment('TRIOMI_VIDEO_URL');
      expect(url, isNotEmpty, reason: 'Use tools/run_ios_video_smoke.py');
      final base = Uri.parse(url);
      expect(
        base.host,
        anyOf('127.0.0.1', 'localhost'),
        reason: 'Smoke is loopback-only',
      );
      final http = TourHttpClient(base);
      if (Platform.isWindows) MediaKit.ensureInitialized();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final preferences = memoryPreferences();
      await preferences.set('player.controls', {
        'skipSeconds': 2,
        'autoNext': false,
      });
      final source = _FixtureSource(url);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          preferencesProvider.overrideWithValue(preferences),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourcesProvider.overrideWith(() => _FixtureRegistry(source)),
          sourceHttpClientProvider.overrideWithValue(http),
          hybridDanmakuClientProvider.overrideWithValue(
            LoopbackDanmakuClient(http),
          ),
          animeSubjectProvider.overrideWith(
            (ref, item) => Stream.value(LoopbackDanmakuClient.subject),
          ),
        ],
      );
      const item = MediaItem(
        sourceId: 'ios-video-smoke',
        remoteId: 'fixture',
        title: 'Actual loopback video',
        type: MediaType.anime,
      );
      const chapter = Chapter(
        sourceId: 'ios-video-smoke',
        remoteId: 'ep1',
        title: '30 second sample',
        number: 1,
      );
      Future<void> until(bool Function() predicate, String reason) async {
        final deadline = DateTime.now().add(const Duration(seconds: 35));
        while (!predicate() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(predicate(), isTrue, reason: reason);
      }

      Slider timeline() => tester.widgetList<Slider>(find.byType(Slider)).first;
      DanmakuController overlay() =>
          tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).controller;
      Future<void> showControls() async {
        if (find.byTooltip('播放设置').hitTestable().evaluate().isEmpty) {
          await tester.tapAt(tester.getCenter(find.byType(DanmakuOverlay)));
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: PlayerPage(
                args: PlayerArgs(
                  item: item,
                  chapters: const [chapter],
                  initialIndex: 0,
                ),
              ),
            ),
          ),
        );
        await until(
          () =>
              find.byType(DanmakuOverlay).evaluate().isNotEmpty &&
              find.byType(Slider).evaluate().isNotEmpty &&
              timeline().max >= 29000 &&
              timeline().value >= 1000,
          'Actual decoder must report 30s duration and advancing position',
        );
        if (Platform.isIOS) {
          expect(
            find.byType(UiKitView),
            findsOneWidget,
            reason: 'iOS smoke requires actual AVPlayer platform view',
          );
        }
        await until(
          () => overlay().active.isNotEmpty,
          'Loopback independent pools must produce active rendered danmaku',
        );
        await captureIosDeviceEvidence('avplayer-playing-danmaku');
        await showControls();
        await tester.tap(find.byTooltip('暂停'));
        await until(
          () => find.byTooltip('播放').evaluate().isNotEmpty,
          'Pause must update real playback state',
        );
        final paused = timeline().value;
        await tester.pump(const Duration(milliseconds: 650));
        expect(timeline().value, closeTo(paused, 300));
        await tester.tap(find.byTooltip('关闭弹幕'));
        await tester.pump();
        expect(overlay().enabled, isFalse);
        expect(overlay().active, isEmpty);
        await tester.tap(find.byTooltip('开启弹幕'));
        await tester.pump();
        expect(overlay().enabled, isTrue);
        await tester.tap(find.byKey(const ValueKey('player-skip')));
        await until(
          () => timeline().value >= paused + 1500,
          'Seek must change actual player position while paused',
        );
        expect(find.byTooltip('播放'), findsOneWidget);
        await tester.tap(find.byTooltip('播放'));
        await until(
          () => find.byTooltip('暂停').evaluate().isNotEmpty,
          'Resume must restart the same player',
        );
        final resumed = timeline().value;
        await until(
          () => timeline().value >= resumed + 500,
          'Resume must advance the actual decoder clock',
        );
        await showControls();
        final sliderBounds = tester.getRect(find.byType(Slider).first);
        await tester.tapAt(
          Offset(sliderBounds.right - 30, sliderBounds.center.dy),
        );
        await until(
          () => timeline().value >= timeline().max - 4000,
          'Production seek control approaches the actual media end',
        );
        await until(
          () =>
              find.byTooltip('播放').evaluate().isNotEmpty &&
              timeline().value >= timeline().max - 1000,
          'Actual decoder completion pauses at EOF',
        );
        final library = LibraryRepository(database);
        final savedDeadline = DateTime.now().add(const Duration(seconds: 10));
        while (await library.chapterPositionOf(
                  item.sourceId,
                  item.remoteId,
                  chapter.remoteId,
                ) !=
                0 &&
            DateTime.now().isBefore(savedDeadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          await library.chapterPositionOf(
            item.sourceId,
            item.remoteId,
            chapter.remoteId,
          ),
          0,
          reason: 'Completed video persists a replay anchor, not EOF',
        );
        await showControls();
        await tester.tap(find.byTooltip('播放'));
        await until(
          () => timeline().value >= 500 && timeline().value < 5000,
          'Play after EOF restarts the same native decoder from the beginning',
        );
        final replayStarted = timeline().value;
        await until(
          () => timeline().value >= replayStarted + 500,
          'Replayed video must advance, not remain paused at zero',
        );
        await tester.pump(const Duration(seconds: 6));
        final savedReplay = await library.chapterPositionOf(
          item.sourceId,
          item.remoteId,
          chapter.remoteId,
        );
        expect(
          savedReplay,
          greaterThan(0),
          reason: 'Replayed video saves actual progress again',
        );
        expect(
          savedReplay,
          lessThan(15),
          reason: 'Replayed history must not restore the old EOF anchor',
        );
        await captureIosDeviceEvidence('avplayer-replayed-persisted');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        await library.recordHistory(
          sourceId: item.sourceId,
          remoteId: item.remoteId,
          chapter: chapter,
          position: 29.5,
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: PlayerPage(
                args: PlayerArgs(
                  item: item,
                  chapters: const [chapter],
                  initialIndex: 0,
                ),
              ),
            ),
          ),
        );
        await until(
          () =>
              find.byType(Slider).evaluate().isNotEmpty &&
              timeline().max >= 29000 &&
              timeline().value >= 29000,
          'Legacy stored last-second anchor reaches the actual decoder',
        );
        await until(
          () => timeline().value >= 500 && timeline().value < 5000,
          'Native legacy EOF callback restarts playback without desktop-player access',
        );
        final legacyRestart = timeline().value;
        await until(
          () => timeline().value >= legacyRestart + 500,
          'Legacy resumed decoder clock advances after automatic replay',
        );
        await tester.pump(const Duration(seconds: 6));
        final savedLegacy = await library.chapterPositionOf(
          item.sourceId,
          item.remoteId,
          chapter.remoteId,
        );
        expect(savedLegacy, greaterThan(0));
        expect(
          savedLegacy,
          lessThan(15),
          reason: 'Legacy EOF no longer traps history at the last half-second',
        );
        expect(tester.takeException(), isNull);
        // ignore: avoid_print
        print(
          'PLAYER_VIDEO_SMOKE (${Platform.operatingSystem}): actual 30s decoding, pause, seek, danmaku, resume, EOF replay and persisted replay progress passed; live upstream matching not exercised',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 500));
        container.dispose();
        http.close();
        await database.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !(Platform.isIOS || Platform.isWindows),
  );
}
