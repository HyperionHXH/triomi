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
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/player/player_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';
import 'player_resume_test.dart' show LocalVideo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iOS legacy EOF resumes through the active native controller', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final database = openTestDatabase();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        downloadRepositoryProvider.overrideWithValue(LocalVideo(database)),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
      ],
    );
    const item = MediaItem(
      sourceId: 'legacy-ios',
      remoteId: 'work',
      title: 'Legacy replay',
      type: MediaType.anime,
    );
    const chapter = Chapter(
      sourceId: 'legacy-ios',
      remoteId: 'episode',
      title: 'Episode',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    MethodChannel? channel;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        channel = MethodChannel(
          'triomi/ios-video/${(call.arguments as Map)['id']}',
        );
        messenger.setMockMethodCallHandler(channel!, (call) async {
          calls.add(call);
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

    Future<void> event(String method, Map<String, Object?> arguments) async {
      final delivered = Completer<void>();
      await messenger.handlePlatformMessage(
        channel!.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (_) => delivered.complete(),
      );
      await delivered.future;
      await settle();
    }

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settle();
      container.dispose();
      await database.close();
      if (channel != null) messenger.setMockMethodCallHandler(channel!, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('triomi/platform'),
        null,
      );
      debugDefaultTargetPlatformOverride = null;
    });
    final library = container.read(libraryRepositoryProvider);
    await tester.runAsync(
      () => library.recordHistory(
        sourceId: item.sourceId,
        remoteId: item.remoteId,
        chapter: chapter,
        position: 119,
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: PlayerPage(
            args: PlayerArgs(item: item, chapters: [chapter], initialIndex: 0),
          ),
        ),
      ),
    );
    await settle();
    final open = calls.singleWhere((call) => call.method == 'open');
    expect((open.arguments as Map)['startMs'], 119000);
    await event('prepared', {
      'positionMs': 119000,
      'durationMs': 120000,
      'playing': true,
    });
    calls.clear();
    await event('completed', {
      'positionMs': 120000,
      'durationMs': 120000,
      'playing': false,
    });
    expect(
      calls.where((call) => call.method == 'open'),
      isEmpty,
      reason: 'Legacy EOF reuses the same native episode',
    );
    expect(calls.where((call) => call.method == 'seek').single.arguments, {
      'positionMs': 0,
    });
    expect(
      calls.where((call) => call.method == 'play'),
      hasLength(1),
      reason: 'Seek alone leaves AVPlayer paused at zero',
    );
    expect(tester.takeException(), isNull);
    await event('state', {
      'positionMs': 12000,
      'durationMs': 120000,
      'playing': true,
    });
    await tester.pump(const Duration(seconds: 6));
    await settle();
    expect(
      await tester.runAsync(
        () => library.chapterPositionOf(
          item.sourceId,
          item.remoteId,
          chapter.remoteId,
        ),
      ),
      12,
    );
    final mediaId = (open.arguments as Map)['mediaId'];
    expect(
      (calls.lastWhere((call) => call.method == 'setSystemMedia').arguments
          as Map)['enabled'],
      isTrue,
    );
    calls.clear();
    await event('mediaCommand', {'mediaId': mediaId, 'command': 'pause'});
    expect(calls.where((call) => call.method == 'pause'), hasLength(1));
    calls.clear();
    await event('mediaCommand', {'mediaId': -1, 'command': 'play'});
    expect(
      calls.where((call) => call.method == 'play'),
      isEmpty,
      reason: 'A retired media session cannot resume the current episode',
    );
    await event('pip', {'enabled': true});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle();
    expect(
      (calls.lastWhere((call) => call.method == 'setSystemMedia').arguments
          as Map)['enabled'],
      isTrue,
      reason:
          'Active PiP keeps system media available without background audio',
    );
    calls.clear();
    await event('mediaCommand', {'mediaId': mediaId, 'command': 'pause'});
    expect(calls.where((call) => call.method == 'pause'), hasLength(1));
    await event('pip', {'enabled': false});
    expect(
      (calls.lastWhere((call) => call.method == 'setSystemMedia').arguments
          as Map)['enabled'],
      isFalse,
    );
    calls.clear();
    await event('mediaCommand', {'mediaId': mediaId, 'command': 'play'});
    expect(calls.where((call) => call.method == 'play'), isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle();
    final navigator = Navigator.of(tester.element(find.byType(PlayerPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Another route')),
        ),
      ),
    );
    await settle();
    expect(
      (calls.lastWhere((call) => call.method == 'setSystemMedia').arguments
          as Map)['enabled'],
      isFalse,
      reason: 'A covered player cannot steal a newer route’s media session',
    );
    calls.clear();
    await event('mediaCommand', {'mediaId': mediaId, 'command': 'play'});
    expect(calls.where((call) => call.method == 'play'), isEmpty);
    navigator.pop();
    await settle();
    expect(
      (calls.lastWhere((call) => call.method == 'setSystemMedia').arguments
          as Map)['enabled'],
      isTrue,
      reason: 'Returning to the player reacquires the native media session',
    );
    await event('mediaCommand', {'mediaId': mediaId, 'command': 'stop'});
    expect(calls.where((call) => call.method == 'seek').last.arguments, {
      'positionMs': 0,
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await settle();
    debugDefaultTargetPlatformOverride = null;
  });
}
