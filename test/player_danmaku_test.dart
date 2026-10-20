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
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/player/data/danmaku_overlay.dart';
import 'package:triomi/features/player/player_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _Source extends ContentSource implements ContentProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(id: 'danmaku', name: 'test',
      type: MediaType.anime, kind: SourceKind.plugin, capabilities: {SourceCapability.content});
  @override
  Future<ChapterContent> content(Chapter chapter) async => ChapterContent(
    playSources: const [PlaySource(name: 'test', url: 'https://video.test/movie.mp4')],
    danmakuUrl: 'https://comments.test/${chapter.remoteId}',
  );
}

class _Sources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async {
    final source = _Source();
    return SourceRegistrySnapshot(entries: [SourceEntry(descriptor: source.descriptor, source: source, enabled: true)], failures: const []);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform source danmaku toggles and cannot leak across episodes', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final database = openTestDatabase();
      final first = Completer<SourceResponse>();
      final second = Completer<SourceResponse>();
      final http = FakeHttpClient((request) => request.url.endsWith('/ep1') ? first.future : second.future);
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(database),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sourceHttpClientProvider.overrideWithValue(http),
        sourcesProvider.overrideWith(_Sources.new),
      ]);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final channels = <MethodChannel>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['id'];
          final channel = MethodChannel(platform == TargetPlatform.iOS
              ? 'triomi/ios-video/$id' : 'triomi/native-video/$id');
          channels.add(channel);
          messenger.setMockMethodCallHandler(channel, (_) async => null);
        }
        return null;
      });
      messenger.setMockMethodCallHandler(const MethodChannel('triomi/platform'), (_) async => true);
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
      }
      Future<void> event(String method, int position) async {
        final done = Completer<void>();
        final values = platform == TargetPlatform.iOS
            ? {'positionMs': position, 'durationMs': 30000, 'playing': true}
            : {'position': position, 'duration': 30000, 'playing': true};
        await messenger.handlePlatformMessage(channels.last.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall(method, values)), (_) => done.complete());
        await done.future;
        await settle();
      }
      DanmakuController overlay() => tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).controller;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await settle();
        container.dispose();
        await database.close();
        for (final channel in channels) { messenger.setMockMethodCallHandler(channel, null); }
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        messenger.setMockMethodCallHandler(const MethodChannel('triomi/platform'), null);
        debugDefaultTargetPlatformOverride = null;
      });
      const item = MediaItem(sourceId: 'danmaku', remoteId: 'show', title: 'show', type: MediaType.anime);
      const chapters = [
        Chapter(sourceId: 'danmaku', remoteId: 'ep1', title: 'one', sortIndex: 0),
        Chapter(sourceId: 'danmaku', remoteId: 'ep2', title: 'two', sortIndex: 1),
      ];
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
        child: const MaterialApp(home: PlayerPage(args: PlayerArgs(item: item, chapters: chapters, initialIndex: 0)))));
      await settle();
      await event('prepared', 1000);
      expect(http.requests.map((r) => r.url), ['https://comments.test/ep1']);
      await tester.tap(find.byTooltip('下一集'));
      await settle();
      await event('prepared', 1000);
      second.complete(const SourceResponse(statusCode: 200, body: '{"comments":[{"p":"1.5,1,16777215,user","m":"new episode"}]}'));
      await settle();
      await event('state', 2000);
      expect(overlay().active.map((entry) => entry.comment.text), contains('new episode'));
      first.complete(const SourceResponse(statusCode: 200, body: '{"comments":[{"p":"2.1,1,16777215,user","m":"stale episode"}]}'));
      await settle();
      await event('state', 2400);
      expect(overlay().active.map((entry) => entry.comment.text), isNot(contains('stale episode')));
      await tester.tap(find.byTooltip('关闭弹幕'));
      await tester.pump();
      expect(overlay().enabled, isFalse);
      expect(overlay().active, isEmpty);
      await tester.tap(find.byTooltip('开启弹幕'));
      await tester.pump();
      expect(overlay().enabled, isTrue);
      expect(http.requests.map((r) => r.url), ['https://comments.test/ep1', 'https://comments.test/ep2']);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
