import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/platform/platform_channel.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/novel/tts/flutter_tts_engine.dart';
import 'package:triomi/features/novel/tts/tts_controller.dart';
import 'package:triomi/features/schedule/data/background_update_check.dart';
import 'package:triomi/features/schedule/data/schedule_providers.dart';
import 'package:triomi/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('actual system TTS and Android background setup', (tester) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final results = <String, Object?>{};
    try {
      final plugin = FlutterTts();
      final engine = FlutterTtsEngine(plugin: plugin);
      final voices = await engine.availableVoices();
      final record = <String, Object?>{
        'stage': 'voices',
        'voiceCount': voices.length,
      };
      results['tts'] = record;
      record['engine'] = Platform.isAndroid
          ? await plugin.getDefaultEngine
          : 'platform system voice';
      expect(voices, isNotEmpty);
      final chinese = voices
          .where(
            (v) =>
                v.locale.toLowerCase().startsWith('zh') &&
                v.installed &&
                !v.networkRequired,
          )
          .firstOrNull;
      record['chineseVoiceAvailable'] = chinese != null;
      record['selectedVoiceOffline'] = chinese != null;
      expect(
        chinese,
        isNotNull,
        reason: 'Actual installed Chinese voice needed',
      );
      await engine.applySpeechSettings(
        rate: 0.5,
        voice: chinese ?? voices.first,
      );
      final completed = Completer<void>();
      Object? synthesisError;
      engine.callbacks = TtsEngineCallbacks(
        onCompleteWithToken: (_, token) {
          if (token == 1 && !completed.isCompleted) completed.complete();
        },
        onError: (error) {
          synthesisError = error;
          if (!completed.isCompleted) completed.complete();
        },
      );
      record['stage'] = 'speak';
      await engine.speak(
        const TtsUtterance(blockIndex: 0, text: '这是 Triomi 系统语音验收。', token: 1),
      );
      await completed.future.timeout(const Duration(seconds: 30));
      if (synthesisError != null) {
        throw StateError('System speech synthesis failed');
      }
      record['naturalCompletion'] = true;
      var lateCompletions = 0;
      engine.callbacks = TtsEngineCallbacks(
        onCompleteWithToken: (_, _) {
          lateCompletions++;
        },
      );
      await engine.speak(
        TtsUtterance(
          blockIndex: 0,
          text: List.filled(40, '开始朗读后立即停止。').join(),
          token: 2,
        ),
      );
      await engine.stop();
      await tester.pump(const Duration(seconds: 2));
      expect(lateCompletions, 0);
      record['stopDiscardedLateCompletion'] = true;
      final bounded = FlutterTtsEngine(
        plugin: plugin,
        synthesisTimeout: const Duration(milliseconds: 200),
      );
      await bounded.applySpeechSettings(rate: 0.1, voice: chinese);
      final failed = Completer<void>();
      bounded.callbacks = TtsEngineCallbacks(
        onError: (_) {
          if (!failed.isCompleted) failed.complete();
        },
      );
      await bounded.speak(
        TtsUtterance(
          blockIndex: 0,
          text: List.filled(100, '验证实际合成超时停止及重试。').join(),
          token: 3,
        ),
      );
      await failed.future.timeout(const Duration(seconds: 5));
      record['realSynthesisDeadlineError'] = true;
      await engine.applySpeechSettings(rate: 0.5, voice: chinese);
      final recovered = Completer<void>();
      engine.callbacks = TtsEngineCallbacks(
        onCompleteWithToken: (_, token) {
          if (token == 4 && !recovered.isCompleted) recovered.complete();
        },
      );
      await engine.speak(
        const TtsUtterance(blockIndex: 0, text: '语音恢复成功。', token: 4),
      );
      await recovered.future.timeout(const Duration(seconds: 30));
      record['errorRecoveryNaturalCompletion'] = true;
      record['status'] = 'passed';
    } catch (error) {
      results['tts'] = {
        ...?results['tts'] as Map<String, Object?>?,
        'status': 'failed',
        'errorType': error.runtimeType.toString(),
      };
    }
    if (Platform.isAndroid) {
      try {
        final days = await container.read(scheduleClientProvider).fetchWeekly();
        final today = days.firstWhere(
          (d) => d.weekday == DateTime.now().weekday,
        );
        expect(today.items, isNotEmpty);
        final entry = today.items.first;
        await container
            .read(libraryRepositoryProvider)
            .addAnimeFollow(
              MediaItem(
                sourceId: bangumiAnimeSourceId,
                remoteId: entry.id,
                type: MediaType.anime,
                title: entry.title,
              ),
            );
        final result = await runBackgroundUpdateCheck(container);
        expect(result, isNotNull);
        expect(await platformChannel.scheduleBackgroundCheck(true), true);
        results['background'] = {
          'status': 'scheduled',
          'realCalendarCount': today.items.length,
          'matchedCount': result!.count,
          'actualNotification':
              'requires native JobScheduler trigger after test',
        };
      } catch (error) {
        results['background'] = {
          'status': 'failed',
          'errorType': error.runtimeType.toString(),
        };
      }
    } else {
      results['background'] = {
        'status': 'not-applicable: Android JobScheduler',
      };
    }
    final evidence = {
      'at': DateTime.now().toUtc().toIso8601String(),
      'environment': '${Platform.operatingSystem} real system plugins',
      'results': results,
    };
    final docs = await getApplicationDocumentsDirectory();
    await File('${docs.path}/android-system-live.json')
        .writeAsString(jsonEncode(evidence), flush: true);
    // ignore: avoid_print
    print('ANDROID_SYSTEM_EVIDENCE ${jsonEncode(evidence)}');
    expect((results['tts'] as Map)['status'], 'passed');
    if (Platform.isAndroid) {
      expect((results['background'] as Map)['status'], 'scheduled');
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
