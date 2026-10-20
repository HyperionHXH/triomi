import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
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
import 'package:triomi/features/player/data/danmaku_overlay.dart';
import 'package:triomi/features/player/player_page.dart';

import '../test/fixtures/fake_preferences.dart';

class _FixtureSource extends ContentSource implements ContentProvider {
  _FixtureSource(this.url);
  final String url;
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'ios-video-smoke', name: 'Loopback video fixture',
    type: MediaType.anime, kind: SourceKind.plugin,
    capabilities: {SourceCapability.content},
  );
  @override
  Future<ChapterContent> content(Chapter chapter) async => ChapterContent(
    playSources: [PlaySource(name: 'fixture', url: url)],
    danmakuUrl: Uri.parse(url).resolve('/danmaku/smoke.json').toString(),
  );
}

class _FixtureRegistry extends SourceRegistryController {
  _FixtureRegistry(this.source);
  final _FixtureSource source;
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [SourceEntry(descriptor: source.descriptor, source: source, enabled: true)],
    failures: const [],
  );
}

/// Uses production PlayerPage and real decoder/network/overlay. No native
/// channel handlers or player state are mocked. Source metadata is a fixture.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real PlayerPage decodes video and toggles source danmaku', (tester) async {
    const url = String.fromEnvironment('TRIOMI_VIDEO_URL');
    expect(url, isNotEmpty, reason: 'Use tools/run_ios_video_smoke.py');
    if (Platform.isWindows) MediaKit.ensureInitialized();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final preferences = memoryPreferences();
    await preferences.set('player.controls', {'skipSeconds': 2, 'autoNext': false});
    final source = _FixtureSource(url);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      preferencesProvider.overrideWithValue(preferences),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourcesProvider.overrideWith(() => _FixtureRegistry(source)),
    ]);
    const item = MediaItem(sourceId: 'ios-video-smoke', remoteId: 'fixture',
        title: 'Actual loopback video', type: MediaType.anime);
    const chapter = Chapter(sourceId: 'ios-video-smoke', remoteId: 'ep1', title: '30 second sample');
    Future<void> until(bool Function() predicate, String reason) async {
      final deadline = DateTime.now().add(const Duration(seconds: 35));
      while (!predicate() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(predicate(), isTrue, reason: reason);
    }
    Slider timeline() => tester.widgetList<Slider>(find.byType(Slider)).first;
    DanmakuController overlay() => tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).controller;
    Future<void> showControls() async {
      if (find.byTooltip('播放设置').hitTestable().evaluate().isEmpty) {
        await tester.tapAt(tester.getCenter(find.byType(DanmakuOverlay)));
        await tester.pump(const Duration(milliseconds: 250));
      }
    }
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: PlayerPage(args: PlayerArgs(item: item, chapters: const [chapter], initialIndex: 0))),
      ));
      await until(() => find.byType(DanmakuOverlay).evaluate().isNotEmpty &&
          find.byType(Slider).evaluate().isNotEmpty && timeline().max >= 29000 && timeline().value >= 1000,
          'Actual decoder must report 30s duration and advancing position');
      await until(() => overlay().active.isNotEmpty, 'Source JSON must produce active rendered danmaku');
      await showControls();
      await tester.tap(find.byTooltip('暂停'));
      await until(() => find.byTooltip('播放').evaluate().isNotEmpty, 'Pause must update real playback state');
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
      await until(() => timeline().value >= paused + 1500, 'Seek must change actual player position while paused');
      expect(find.byTooltip('播放'), findsOneWidget);
      await tester.tap(find.byTooltip('播放'));
      await until(() => find.byTooltip('暂停').evaluate().isNotEmpty, 'Resume must restart the same player');
      // Keep the real surface available long enough for host observation.
      await tester.pump(const Duration(seconds: 2));
      // ignore: avoid_print
      print('PLAYER_VIDEO_SMOKE (${Platform.operatingSystem}): actual 30s decoding, advancing/paused position, seek, source danmaku toggle and resume passed');
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
      container.dispose();
      await database.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)), skip: !(Platform.isIOS || Platform.isWindows));
}
