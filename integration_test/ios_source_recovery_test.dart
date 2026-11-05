import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_restore_preview.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/catalog_installer.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/profile/backup_restore_dialog.dart';
import 'package:triomi/features/sources/sources_page.dart';

import '../test/fixtures/fake_http_client.dart';
import '../test/fixtures/fake_preferences.dart';
import 'fixtures/ios_test_binding.dart';

String _rule(String id, {String? feature, String version = '1.0.0'}) =>
    jsonEncode({
      'id': id,
      'name': id,
      'type': 'manga',
      'version': version,
      'baseUrl': 'https://recovery.example.invalid',
      'capabilities': ['search'],
      if (feature != null) 'requiresHost': [feature],
      'search': {
        'url': '/search?q={keywordEncoded}',
        'list': 'a',
        'fields': {'title': '.', 'remoteId': '@href'},
      },
    });

void main() {
  initializeIosIntegrationBinding();

  testWidgets(
    'native backup restores compatible rules and repairs metadata without losing books',
    (tester) async {
      await tester.runAsync(() async {
        final source = AppDatabase.forTesting(NativeDatabase.memory());
        final target = AppDatabase.forTesting(NativeDatabase.memory());
        final sourceRepository = SourceRepository(source);
        final targetRepository = SourceRepository(target);
        final http = FakeHttpClient(
          (_) async => throw StateError('Backup must not access the network'),
        );
        File? backup;
        SourceRegistry? registry;
        try {
          for (final id in ['future', 'compatible', 'local', 'native']) {
            await sourceRepository.upsert(
              id: id,
              name: id,
              type: MediaType.manga,
              kind: SourceKind.plugin,
              version: '1.0.0',
              ruleText: _rule(
                id,
                feature: id == 'future' ? 'future.gateway.v9' : null,
              ),
            );
          }
          final now = DateTime.utc(2026);
          await source
              .into(source.mediaItems)
              .insert(
                MediaItemsCompanion.insert(
                  sourceId: 'future',
                  remoteId: 'book',
                  type: MediaType.manga,
                  title: 'Recovery fixture',
                ),
              );
          await source
              .into(source.libraryEntries)
              .insert(
                LibraryEntriesCompanion.insert(
                  sourceId: 'future',
                  remoteId: 'book',
                  type: MediaType.manga,
                  progress: const Value(7),
                  addedAt: now,
                  updatedAt: now,
                ),
              );
          await source
              .into(source.histories)
              .insert(
                HistoriesCompanion.insert(
                  sourceId: 'future',
                  remoteId: 'book',
                  chapterSourceId: 'future',
                  chapterRemoteId: 'chapter',
                  position: const Value(3),
                  visitedAt: now,
                ),
              );
          final localText = _rule('local', version: '2.0.0');
          await targetRepository.upsert(
            id: 'local',
            name: 'Current local rule',
            type: MediaType.manga,
            kind: SourceKind.plugin,
            ruleText: localText,
            version: '2.0.0',
            enabled: true,
          );
          await targetRepository.upsert(
            id: 'native',
            name: 'Native identity',
            type: MediaType.manga,
            kind: SourceKind.builtin,
            enabled: true,
          );
          final native = await targetRepository.byId('native');
          final exporter = BackupService(
            database: source,
            preferences: memoryPreferences(),
            http: http,
          );
          final slim = await exporter.exportToBytes(includeCovers: false);
          expect(
            BackupService.validatedPayload(slim.bytes)['sourceRuleDefinitions'],
            isNull,
          );
          final exported = await exporter.exportToFile(
            includeCovers: false,
            includeOfflineContent: false,
            includeSourceRules: true,
          );
          backup = File(exported.path);
          final preview = await previewBackupRestoreFile(target, backup.path);
          expect(preview.incomingSourceRules, 1);
          expect(preview.unsupportedSourceRules, 1);
          expect(preview.keptSourceRules, 2);
          final importer = BackupService(
            database: target,
            preferences: memoryPreferences(),
            http: http,
          );
          await importer.importFromBytes(slim.bytes);
          expect((await targetRepository.byId('future'))!.ruleText, isNull);
          expect((await targetRepository.byId('compatible'))!.ruleText, isNull);
          final restored = await importer.importFromFile(
            backup.path,
            options: const BackupRestoreOptions(restoreSourceRules: true),
            expectedHash: preview.byteHash,
          );
          expect(restored.sourceRules, 1);
          expect(restored.unsupportedSourceRules, 1);
          expect((await targetRepository.byId('compatible'))!.enabled, false);
          expect(
            (await targetRepository.byId('compatible'))!.ruleText,
            _rule('compatible'),
          );
          expect((await targetRepository.byId('future'))!.ruleText, isNull);
          expect((await targetRepository.byId('local'))!.ruleText, localText);
          expect(await targetRepository.byId('native'), native);
          expect(http.requests, isEmpty);

          // The catalog repairs missing code even when metadata claims the same version.
          final catalogHttp = FakeHttpClient(
            (request) async => SourceResponse(
              statusCode: 200,
              url: request.url,
              body: _rule('future'),
            ),
          );
          registry = SourceRegistry(
            repository: targetRepository,
            http: catalogHttp,
          );
          await CatalogInstaller(registry).install(
            const SourceCatalogEntry(
              id: 'future',
              name: 'future',
              type: MediaType.manga,
              version: CatalogVersion(1, 0, 0),
              url: 'https://recovery.example.invalid/rule.json',
              capabilities: {SourceCapability.search},
            ),
          );
          expect(
            (await targetRepository.byId('future'))!.ruleText,
            _rule('future'),
          );
          expect((await targetRepository.byId('future'))!.enabled, false);
          expect(catalogHttp.requests, hasLength(1));
          await target
              .into(target.downloads)
              .insert(
                DownloadsCompanion.insert(
                  sourceId: 'future',
                  remoteId: 'book',
                  chapterSourceId: 'future',
                  chapterRemoteId: 'chapter',
                  status: 'done',
                  createdAt: now,
                ),
              );
          await registry.remove('future');
          expect(await targetRepository.byId('future'), isNull);
          expect(
            (await target.select(target.libraryEntries).get()).single.progress,
            7,
          );
          expect(
            (await target.select(target.histories).get()).single.position,
            3,
          );
          expect(await target.select(target.downloads).get(), hasLength(1));
        } finally {
          registry?.dispose();
          await source.close();
          await target.close();
          if (backup != null && await backup.exists()) await backup.delete();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final reject in [false, true]) {
    testWidgets(
      'native failed-rule removal confirms and preserves failures: $reject',
      (tester) async {
        final controller = _RecoverySources(rejectRemoval: reject);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(memoryPreferences()),
              sourcesProvider.overrideWith(() => controller),
            ],
            child: const MaterialApp(
              home: SourcesPage(initialType: MediaType.manga),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('移除来源 Recovery fixture'));
        await tester.pumpAndSettle();
        expect(find.textContaining('书架、阅读记录和已下载内容保留'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(controller.removed, false);
        await tester.tap(find.byTooltip('移除来源 Recovery fixture'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移除'));
        await tester.pumpAndSettle();
        expect(controller.removed, !reject);
        expect(
          find.byTooltip('移除来源 Recovery fixture'),
          reject ? findsOneWidget : findsNothing,
        );
        if (reject) expect(find.textContaining('移除来源失败：'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'native restore preview explains unsupported code and keeps rule restore off',
    (tester) async {
      BackupRestoreOptions? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await confirmBackupRestore(
                    context,
                    const BackupRestorePreview(
                      incomingWins: 1,
                      localWins: 0,
                      equalTimestampConflicts: 0,
                      byteHash: 'isolated-fixture',
                      unsupportedSourceRules: 1,
                    ),
                    target: 'Isolated recovery fixture',
                  );
                },
                child: const Text('Review recovery'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review recovery'));
      await tester.pumpAndSettle();
      expect(find.textContaining('另有 1 个规则'), findsOneWidget);
      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '恢复规则定义（保持停用）'),
      );
      expect(tile.value, false);
      expect(tile.onChanged, isNull);
      await tester.ensureVisible(find.text('确认合并当前备份'));
      await tester.tap(find.text('确认合并当前备份'));
      await tester.pumpAndSettle();
      expect(selected?.restoreSourceRules, false);
      expect(selected?.restoreApkPackages, false);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

class _RecoverySources extends SourceRegistryController {
  _RecoverySources({required this.rejectRemoval});
  final bool rejectRemoval;
  bool removed = false;

  SourceRegistrySnapshot get snapshot => SourceRegistrySnapshot(
    entries: const [],
    failures: removed
        ? const []
        : const [
            SourceFailure(
              id: 'recovery-fixture',
              name: 'Recovery fixture',
              type: MediaType.manga,
              message: 'Rule metadata has no executable definition',
            ),
          ],
  );

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;

  @override
  Future<void> remove(String id) async {
    if (rejectRemoval) throw StateError('Isolated database failure');
    removed = true;
    state = AsyncData(snapshot);
  }
}
