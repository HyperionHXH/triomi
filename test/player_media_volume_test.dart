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
import 'package:triomi/features/player/data/player_settings.dart';
import 'package:triomi/features/player/player_interaction_surface.dart';
import 'package:triomi/features/player/player_menu.dart';
import 'package:triomi/features/player/player_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _LocalVideo extends DownloadRepository {
  _LocalVideo(super.db);
  @override
  Future<String?> localVideoPath(
    String sourceId,
    String chapterRemoteId,
  ) async => 'D:/public-test-video.mp4';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android consumes device volume, snaps settings, observes keys and never restores app gain',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final db = openTestDatabase();
      final preferences = memoryPreferences();
      await const PlayerSettings(volume: .9).save(preferences);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          downloadRepositoryProvider.overrideWithValue(_LocalVideo(db)),
          preferencesProvider.overrideWithValue(preferences),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
        ],
      );
      const item = MediaItem(
        sourceId: 'volume',
        remoteId: 'anime',
        title: 'Anime',
        type: MediaType.anime,
      );
      const chapters = [
        Chapter(
          sourceId: 'volume',
          remoteId: 'ep1',
          title: 'Episode 1',
          volumeTitle: 'main',
        ),
        Chapter(
          sourceId: 'volume',
          remoteId: 'ep2',
          title: 'Episode 2',
          volumeTitle: 'main',
          sortIndex: 1,
        ),
      ];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final channels = <MethodChannel>[];
      final calls = <MethodCall>[];
      var index = 3;
      var canSet = true;
      String? error;
      Map<String, Object?> state() => {
        'position': 12000,
        'duration': 120000,
        'bufferedPosition': 30000,
        'playing': true,
        'mediaVolume': index / 10,
        'mediaVolumeIndex': index,
        'mediaVolumeMin': 0,
        'mediaVolumeMax': 10,
        'mediaVolumeCanSet': canSet,
        'mediaVolumeError': error,
      };
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          final channel = MethodChannel(
            'triomi/native-video/${(call.arguments as Map)['id']}',
          );
          channels.add(channel);
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'getState' || call.method == 'getMediaVolume') {
              return state();
            }
            if (call.method == 'setMediaVolume') {
              if (canSet) {
                index = (((call.arguments as Map)['volume'] as num) * 10)
                    .round()
                    .clamp(0, 10);
              }
              return state();
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
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      Future<void> event(String name) async {
        final delivered = Completer<void>();
        await messenger.handlePlatformMessage(
          channels.last.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(name, state()),
          ),
          (_) => delivered.complete(),
        );
        await delivered.future;
        await settle();
      }

      Widget page() => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: PlayerPage(
            args: PlayerArgs(item: item, chapters: chapters, initialIndex: 0),
          ),
        ),
      );
      PlayerInteractionSurface surface() =>
          tester.widget(find.byType(PlayerInteractionSurface));
      PlayerMenu menu() => tester.widget(find.byType(PlayerMenu));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await settle();
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(channel, null);
        }
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        messenger.setMockMethodCallHandler(
          const MethodChannel('triomi/platform'),
          null,
        );
        container.dispose();
        await db.close();
        await tester.pump(const Duration(seconds: 6));
      });

      try {
        await tester.pumpWidget(page());
        await settle();
        expect(
          surface().volume,
          .3,
          reason: 'Initial UI uses the device, even before prepared',
        );
        expect(menu().settings.volume, .3);
        await event('prepared');
        await menu().onSettingsChanged(menu().settings.copyWith(speed: 1.5));
        await settle();
        await tester.tap(find.byTooltip('剧集'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.widgetWithText(OutlinedButton, 'Episode 2'));
        await settle();
        expect(
          calls.where(
            (call) =>
                call.method == 'setMediaVolume' || call.method == 'setVolume',
          ),
          isEmpty,
        );

        await event('prepared');
        index = 6;
        await event('state');
        expect(
          surface().volume,
          .6,
          reason: 'Physical keys/OS updates reach gestures',
        );
        expect(menu().settings.volume, .6);
        expect(await menu().onVolumeChanged!(.46), .5);
        await settle();
        expect(index, 5);
        expect(
          menu().settings.volume,
          .5,
          reason: 'Snapped readback reaches the menu',
        );
        expect(surface().volume, .5);
        expect(
          PlayerSettings.load(preferences).volume,
          .9,
          reason: 'Android must preserve the desktop app gain preference',
        );

        canSet = false;
        error = 'media_volume_fixed';
        await event('state');
        expect(surface().volumeEnabled, isFalse);
        expect(menu().volumeEnabled, isFalse);
        expect(menu().volumeStatus, '此设备使用固定音量');
        await tester.pumpWidget(const SizedBox());
        await settle();
        index = 2;
        await tester.pumpWidget(page());
        await settle();
        expect(
          surface().volume,
          .2,
          reason: 'Reopening queries current device, not persisted gain',
        );
        expect(
          calls.where((call) => call.method == 'setMediaVolume'),
          hasLength(1),
        );
        expect(calls.where((call) => call.method == 'setVolume'), isEmpty);
      } finally {
        // Dispose the Android native view before restoring the test platform.
        await tester.pumpWidget(const SizedBox());
        await settle();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
