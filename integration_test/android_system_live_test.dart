import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/platform/platform_channel.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/schedule/data/background_update_check.dart';
import 'package:triomi/features/schedule/data/schedule_providers.dart';
import 'package:triomi/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('actual Android background setup', (tester) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final results = <String, Object?>{};
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
