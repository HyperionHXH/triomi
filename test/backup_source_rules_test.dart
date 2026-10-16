import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_restore_preview.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';
import 't2_js_source_test.dart' show jsRuleText;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    docs = await Directory.systemTemp.createTemp('rule-backup-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => docs.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await docs.delete(recursive: true);
  });

  test('explicit rule backup fills metadata-only placeholders without executing or overwriting local rules', () async {
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    final http = FakeHttpClient(
      (_) async => throw StateError('No network expected'),
    );
    final original = SourceRegistry(
      repository: SourceRepository(source),
      http: http,
    );
    addTearDown(original.dispose);
    await original.importFromText(
      jsRuleText(script: 'throw new Error("must stay disabled");').replaceFirst('"type":', '"nsfw": true, "type":'),
    );
    await original.importFromText(
      '''{"id":"plain","name":"Plain","type":"manga","version":"1","baseUrl":"https://example.test","search":{"url":"/search?q={keyword}","list":".item","fields":{"title":".title","remoteId":"a@href"}}}''',
    );
    final kazumi = await File('assets/rules/kazumi-7sefun.json').readAsString();
    final kazumiDescriptor = await original.importFromText(kazumi);
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
    final backup = await exporter.exportToFile(
      includeCovers: false,
      includeSourceRules: true,
    );
    expect(backup.summary.sourceRules, 3);
    final importer = BackupService(
      database: target,
      preferences: memoryPreferences(),
      http: http,
    );
    await importer.importFromFile(backup.path);
    expect(
      (await SourceRepository(
        target,
      ).all()).every((row) => row.ruleText == null),
      true,
    );
    final preview = await previewBackupRestoreFile(target, backup.path);
    expect(preview.incomingSourceRules, 3);
    expect(preview.keptSourceRules, 0);
    const options = BackupRestoreOptions(restoreSourceRules: true);
    final restored = await importer.importFromFile(
      backup.path,
      options: options,
      expectedHash: preview.byteHash,
    );
    expect(restored.sourceRules, 3);
    final registry = SourceRegistry(
      repository: SourceRepository(target),
      http: http,
      jsRuntimeFactory: () =>
          throw StateError('Disabled script must not initialize'),
    );
    addTearDown(registry.dispose);
    final snapshot = await registry.load();
    expect(snapshot.failures, isEmpty);
    expect(snapshot.enabledEntries, isEmpty);
    expect(snapshot.entries.singleWhere((entry) => entry.descriptor.id == 'js-source').descriptor.nsfw, isTrue);
    expect(
      (await SourceRepository(target).byId(kazumiDescriptor.id))!.ruleText,
      kazumi,
    );
    await SourceRepository(target).upsert(
      id: 'js-source',
      name: 'Local version',
      type: MediaType.manga,
      kind: SourceKind.plugin,
      ruleText: jsRuleText(script: 'function search() { return []; }'),
      enabled: true,
    );
    final again = await importer.importFromFile(backup.path, options: options);
    expect(again.sourceRules, 0);
    final local = (await SourceRepository(target).byId('js-source'))!;
    expect(local.name, 'Local version');
    expect(local.enabled, true);
    expect(local.ruleText, contains('function search()'));
    expect(
      (await previewBackupRestoreFile(target, backup.path)).keptSourceRules,
      3,
    );
  });

  for (final invalid in ['identity', 'duplicate', 'cookie', 'url']) {
    test(
      'rejects $invalid rules before settings or database mutation',
      () async {
        final db = openTestDatabase();
        addTearDown(db.close);
        final prefs = memoryPreferences();
        await prefs.set('theme', 'before');
        final rule = jsonDecode(jsRuleText()) as Map<String, dynamic>;
        if (invalid == 'identity') rule['id'] = 'different-source';
        if (invalid == 'cookie') {
          rule['headers'] = {'Cookie': 'fixture-session'};
        }
        if (invalid == 'url') {
          rule['baseUrl'] = 'https://example.test/?token=fixture-private';
        }
        final definition = {'id': 'js-source', 'ruleText': jsonEncode(rule)};
        final payload = {
          'version': 1,
          'sourceRows': [
            {
              'id': 'js-source',
              'name': 'JS',
              'type': 'manga',
              'kind': 'plugin',
            },
          ],
          'sourceRuleDefinitions': [
            definition,
            if (invalid == 'duplicate') definition,
          ],
          'settingsValues': {'theme': 'after'},
        };
        final file = File('${docs.path}/invalid.zip');
        final archive = Archive()
          ..addFile(
            ArchiveFile.bytes(
              'data.json',
              Uint8List.fromList(utf8.encode(jsonEncode(payload))),
            ),
          );
        await file.writeAsBytes(ZipEncoder().encode(archive));
        final service = BackupService(
          database: db,
          preferences: prefs,
          http: FakeHttpClient(
            (_) async => throw StateError('No network expected'),
          ),
        );
        await expectLater(
          previewBackupRestoreFile(db, file.path),
          throwsFormatException,
        );
        await expectLater(
          service.importFromFile(
            file.path,
            options: const BackupRestoreOptions(restoreSourceRules: true),
          ),
          throwsFormatException,
        );
        expect(prefs.get<String>('theme'), 'before');
        expect(await SourceRepository(db).all(), isEmpty);
        expect(await db.select(db.backupImportJournals).get(), isEmpty);
      },
    );
  }

  test('rule restore rolls back with later SQL failure and never fills native builtin identities', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final prefs = memoryPreferences();
    await prefs.set('theme', 'before');
    final repository = SourceRepository(db);
    await repository.upsert(
      id: 'js-source',
      name: 'Native',
      type: MediaType.manga,
      kind: SourceKind.builtin,
      enabled: true,
    );
    final payload = {
      'version': 1,
      'sourceRows': [
        {'id': 'js-source', 'name': 'JS', 'type': 'manga', 'kind': 'plugin'},
      ],
      'sourceRuleDefinitions': [
        {'id': 'js-source', 'ruleText': jsRuleText()},
      ],
      'settingsValues': {'theme': 'after'},
    };
    Uint8List zip() => Uint8List.fromList(
      ZipEncoder().encode(
        Archive()..addFile(
          ArchiveFile.bytes(
            'data.json',
            Uint8List.fromList(utf8.encode(jsonEncode(payload))),
          ),
        ),
      ),
    );
    final service = BackupService(
      database: db,
      preferences: prefs,
      http: FakeHttpClient(
        (_) async => throw StateError('No network expected'),
      ),
    );
    final bytes = zip();
    expect((await previewBackupRestore(db, bytes)).keptSourceRules, 1);
    final summary = await service.importFromBytes(
      bytes,
      options: const BackupRestoreOptions(restoreSourceRules: true),
    );
    expect(summary.sourceRules, 0);
    final native = (await repository.byId('js-source'))!;
    expect(native.ruleText, isNull);
    expect(native.enabled, true);
    await repository.remove('js-source');
    payload['downloadRows'] = [
      {'sourceId': 'missing-required-fields'},
    ];
    await prefs.set('theme', 'before');
    await expectLater(
      service.importFromBytes(
        zip(),
        options: const BackupRestoreOptions(restoreSourceRules: true),
      ),
      throwsA(anything),
    );
    expect(await repository.all(), isEmpty);
    expect(prefs.get<String>('theme'), 'before');
    expect(await db.select(db.backupImportJournals).get(), isEmpty);
  });
}
