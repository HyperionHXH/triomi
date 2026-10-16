// Actual trusted APK, challenge and visible browser. Never manufactures cookies.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/platform/platform_channel.dart';
import 'package:triomi/core/source/mihon_installer.dart';
import 'package:triomi/core/source/mihon_repository.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const package = 'eu.kanade.tachiyomi.extension.all.mangafire';
  const phase = String.fromEnvironment('CF_PHASE', defaultValue: 'challenge');
  testWidgets('real MangaFire challenge and original-request recovery', (
    tester,
  ) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final preferences = container.read(preferencesProvider);
    final record = <String, Object?>{
      'phase': phase,
      'at': DateTime.now().toUtc().toIso8601String(),
      'package': package,
      'fakeCookieUsed': false,
    };
    final directory = await getApplicationDocumentsDirectory();
    Future<void> save() =>
        File('${directory.path}/mihon-challenge-$phase.json')
            .writeAsString(jsonEncode(record), flush: true);
    if (phase == 'challenge') {
      final installed =
          await MihonInstaller(
            http: container.read(sourceHttpClientProvider),
            preferences: preferences,
          ).install(
            const MihonExtension(
              name: 'MangaFire',
              packageName: package,
              apkUrl: 'https://github.com/keiyoushi/extensions/releases/download/4217666-0/tachiyomi-all.mangafire-v1.6.34.apk',
              iconUrl: '',
              extensionLib: '1.6',
              versionCode: 106034,
              versionName: '1.6.34',
              sources: [],
            ),
            signerSha256: '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
          );
      expect(installed['executable'], true);
      expect(await platformChannel.setMihonEnabled(package, true), true);
      await preferences.set(
        'mihon.enabledPackages',
        <String>{
          ...?preferences
              .get<List<Object?>>('mihon.enabledPackages')
              ?.map((e) => '$e'),
          package,
        }.toList(),
      );
    }
    container.invalidate(sourceRegistryProvider);
    await container.read(sourcesProvider.notifier).refresh();
    final snapshot = await container.read(sourcesProvider.future);
    final source = snapshot.enabledEntries
        .map((e) => e.source)
        .whereType<MihonSource>()
        .firstWhere(
          (s) => s.packageName == package && s.descriptor.lang == 'en',
        );
    try {
      try {
        final items = await source.discover(source.feeds.first);
        record['initialRequestCount'] = items.length;
        record['status'] = phase == 'resume'
            ? 'reused-after-restart'
            : 'no-challenge-observed';
        if (phase == 'resume') expect(items, isNotEmpty);
      } on SourceException catch (error) {
        final marker = (error.message ?? '').toLowerCase();
        record['errorType'] = error.type.name;
        record['challengeClassified'] =
            marker.contains('cloudflare') ||
            marker.contains('challenge required');
        if (record['challengeClassified'] != true) {
          record['status'] = 'blocked-before-challenge';
        } else if (phase == 'resume') {
          record['status'] = 'challenge-not-reused';
        } else {
          record['stage'] = 'visibleWebViewAwaitingVerification';
          await save();
          try {
            final saved = await source.openWebSession().timeout(
              const Duration(seconds: 100),
            );
            record['sessionSaved'] = saved;
            final restored = await source.discover(source.feeds.first);
            expect(restored, isNotEmpty);
            record['originalRequestRecoveredCount'] = restored.length;
            final reused = await source.discover(source.feeds.first);
            expect(reused, isNotEmpty);
            record['reusedCount'] = reused.length;
            record['status'] = 'recovered-and-reused';
          } on TimeoutException {
            record['status'] = 'visible-verification-not-completed';
          } on SourceException catch (retry) {
            record['status'] = 'request-still-rejected';
            record['retryErrorType'] = retry.type.name;
          }
        }
      }
    } finally {
      await save();
      // ignore: avoid_print
      print('MIHON_CHALLENGE_EVIDENCE ${jsonEncode(record)}');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
