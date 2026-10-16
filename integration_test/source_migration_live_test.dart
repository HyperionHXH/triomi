import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/platform/platform_channel.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/main.dart' as app;

// Actual MangaDex rule -> actual MangaDex APK, same work on both adapters.
// No provider, network or storage overrides. Does not request account data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const phase = String.fromEnvironment(
    'SOURCE_MIGRATION_PHASE',
    defaultValue: 'copy',
  );
  testWidgets('real cross-source shelf copy and restart: $phase', (
    tester,
  ) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final preferences = container.read(preferencesProvider);
    final library = container.read(libraryRepositoryProvider);
    final db = container.read(databaseProvider);
    final dir = await getApplicationDocumentsDirectory();
    final record = <String, Object?>{
      'phase': phase,
      'at': DateTime.now().toUtc().toIso8601String(),
      'environment':
          'actual Android storage, real rule/API and genuine APK; no fixtures',
    };

    Future<void> waitFor(Finder finder, {int seconds = 90}) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(finder, findsWidgets);
    }

    Future<void> write() async {
      await File('${dir.path}/source-migration-$phase.json')
          .writeAsString(jsonEncode(record), flush: true);
      // ignore: avoid_print
      print('SOURCE_MIGRATION_EVIDENCE ${jsonEncode(record)}');
    }

    try {
      if (phase == 'copy') {
        record['stage'] = 'load-genuine-apk';
        const package = 'eu.kanade.tachiyomi.extension.all.mangadex';
        final apk = File(
          '${dir.parent.path}/files/mihon-regression/$package.apk',
        );
        expect(
          await apk.exists(),
          true,
          reason: 'Transfer original signed APK to app-private directory first',
        );
        final status = await platformChannel.inspectMihonExtension(
          apkPath: apk.path,
          packageName: package,
          versionCode: 106000,
          signerSha256: '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
        );
        expect(status['ok'], true);
        expect(status['signatureVerified'], true);
        expect(await platformChannel.setMihonEnabled(package, true), true);
        await preferences.set('mihon.hostStatus', {
          ...?preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus'),
          package: status,
        });
        await preferences.set(
          'mihon.enabledPackages',
          {
            ...?preferences
                .get<List<Object?>>('mihon.enabledPackages')
                ?.map((v) => '$v'),
            package,
          }.toList(),
        );
        container.invalidate(sourceRegistryProvider);
        await container.read(sourcesProvider.notifier).refresh();
        final snapshot = await container.read(sourcesProvider.future);
        final targetSource = snapshot.enabledEntries
            .map((e) => e.source)
            .whereType<MihonSource>()
            .firstWhere(
              (s) => s.packageName == package && s.descriptor.lang == 'zh-Hans',
            );
        final oldSource =
            snapshot.enabledEntries
                    .firstWhere((s) => s.descriptor.id == 'mangadex')
                    .source
                as DetailProvider;
        record['stage'] = 'find-real-work';
        // The genuine APK's current popular feed can be empty. Its supported
        // exact-URL lookup still accepts works discovered by the rule adapter.
        final discoverSource = oldSource as DiscoverProvider;
        final candidates = await discoverSource.discover(
          discoverSource.feeds.first,
        );
        record['candidateCount'] = candidates.length;
        final examined = <Map<String, Object?>>[];
        record['examinedCandidates'] = examined;
        MediaItem? oldItem;
        MediaItem? newItem;
        String? resumeId;
        String? query;
        for (final originalCandidate in candidates.take(12)) {
          final probe = <String, Object?>{};
          examined.add(probe);
          if (await library.lastReadOf(
                originalCandidate.sourceId,
                originalCandidate.remoteId,
              ) !=
              null) {
            probe['existingOriginalHistory'] = true;
            continue;
          }
          final id = RegExp(
            r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}',
          ).firstMatch(originalCandidate.remoteId)?.group(0);
          probe['idHasUuid'] = id != null;
          if (id == null) continue;
          final matches = await targetSource.search(
            'https://mangadex.org/title/$id',
          );
          probe['targetExactUrlCount'] = matches.length;
          final candidate = matches
              .where((m) => m.remoteId.contains(id))
              .firstOrNull;
          if (candidate == null) continue;
          if (await library.isInLibrary(
                candidate.sourceId,
                candidate.remoteId,
              ) ||
              await library.lastReadOf(
                    candidate.sourceId,
                    candidate.remoteId,
                  ) !=
                  null) {
            probe['existingDestination'] = true;
            continue;
          }
          final targetChapters = await targetSource.chapters(candidate);
          probe['targetDirectoryCount'] = targetChapters.length;
          if (targetChapters.isEmpty) continue;
          final original = await oldSource.detail(originalCandidate);
          final oldChapters = await oldSource.chapters(original);
          probe['originalDirectoryCount'] = oldChapters.length;
          if (oldChapters.isEmpty) continue;
          final common = targetChapters
              .where(
                (t) =>
                    !t.locked &&
                    oldChapters.any((o) => t.remoteId.contains(o.remoteId)),
              )
              .firstOrNull;
          if (common == null) continue;
          final oldChapter = oldChapters.firstWhere(
            (o) => common.remoteId.contains(o.remoteId),
          );
          await library.addToLibrary(original);
          await library.saveChapters(
            itemSourceId: original.sourceId,
            itemRemoteId: original.remoteId,
            chapters: oldChapters,
          );
          await library.recordHistory(
            sourceId: original.sourceId,
            remoteId: original.remoteId,
            chapter: oldChapter,
            position: 3,
          );
          oldItem = original;
          newItem = candidate;
          resumeId = common.remoteId;
          query = 'https://mangadex.org/title/$id';
          break;
        }
        expect(
          oldItem,
          isNotNull,
          reason: 'A real shared readable work is required',
        );
        record['stage'] = 'production-copy-ui';
        final original = oldItem!;
        final target = newItem!;
        final oldHistory = await library.lastReadOf(
          original.sourceId,
          original.remoteId,
        );
        final downloadsBefore = await db.select(db.downloads).get();
        unawaited(
          container
              .read(routerProvider)
              .push<void>(AppRoutes.detailFor(original), extra: original),
        );
        await waitFor(find.byTooltip('复制到其他来源'));
        await tester.tap(find.byTooltip('复制到其他来源'));
        await waitFor(find.text('搜索目标作品'));
        final sourceDropdown = find
            .byType(DropdownButtonFormField<String>)
            .first;
        await tester.tap(sourceDropdown);
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('${targetSource.descriptor.name} · zh-Hans').last,
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), query!);
        await tester.tap(find.text('搜索目标作品'));
        await waitFor(find.byType(ListTile));
        final itemTile = find
            .byWidgetPredicate((w) => w is ListTile && w.onTap != null)
            .first;
        await tester.tap(itemTile);
        await waitFor(find.text('复制到本地书架'));
        // Confirm chapter identity from the actual target directory, never map by index.
        final chapterDropdown = find
            .byType(DropdownButtonFormField<String>)
            .last;
        final form = tester.widget<DropdownButtonFormField<String>>(
          chapterDropdown,
        );
        if (form.initialValue != resumeId) {
          await tester.ensureVisible(chapterDropdown);
          await tester.tap(chapterDropdown);
          await tester.pumpAndSettle();
          final menu = find
              .byWidgetPredicate(
                (w) => w is DropdownMenuItem<String> && w.value == resumeId,
              )
              .hitTestable()
              .first;
          await tester.ensureVisible(menu);
          await tester.tap(menu);
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(find.text('复制到本地书架'));
        await tester.tap(find.text('复制到本地书架'));
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!await library.isInLibrary(target.sourceId, target.remoteId) &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(
          await library.isInLibrary(target.sourceId, target.remoteId),
          true,
        );
        expect(
          await library.chapterPositionOf(
            target.sourceId,
            target.remoteId,
            resumeId!,
          ),
          0,
        );
        expect(
          (await library.lastReadOf(
            original.sourceId,
            original.remoteId,
          ))!.position,
          oldHistory!.position,
        );
        expect(await db.select(db.downloads).get(), downloadsBefore);
        await preferences.set('acceptance.sourceMigration', {
          'old': original.toJson(),
          'target': target.toJson(),
          'resumeChapterId': resumeId,
        });
        await preferences.flush();
        record.addAll({
          'status': 'passed',
          'oldTitle': original.title,
          'targetTitle': target.title,
          'targetSource': targetSource.descriptor.id,
          'originalPosition': oldHistory.position,
          'targetPosition': 0,
          'downloadsUnchanged': true,
        });
      } else {
        final saved = preferences.get<Map<dynamic, dynamic>>(
          'acceptance.sourceMigration',
        )!;
        final targetRaw = (saved['target'] as Map).cast<String, Object?>();
        final oldRaw = (saved['old'] as Map).cast<String, Object?>();
        final target = MediaItem.fromJson(
          targetRaw,
          sourceId: '${targetRaw['sourceId']}',
        );
        final original = MediaItem.fromJson(
          oldRaw,
          sourceId: '${oldRaw['sourceId']}',
        );
        expect(
          await library.isInLibrary(target.sourceId, target.remoteId),
          true,
        );
        expect(
          await library.isInLibrary(original.sourceId, original.remoteId),
          true,
        );
        expect(
          await library.chapterPositionOf(
            target.sourceId,
            target.remoteId,
            '${saved['resumeChapterId']}',
          ),
          0,
        );
        expect(
          (await library.lastReadOf(
            original.sourceId,
            original.remoteId,
          ))!.position,
          3,
        );
        record.addAll({
          'status': 'passed',
          'oldAndTargetShelfPersisted': true,
          'targetResumeAtChapterStart': true,
        });
      }
    } catch (error) {
      record['status'] = 'failed';
      record['errorType'] = error.runtimeType.toString();
      rethrow;
    } finally {
      await write();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
