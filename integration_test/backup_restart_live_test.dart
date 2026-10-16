import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/backup/backup_import_recovery.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const phase = String.fromEnvironment(
    'BACKUP_RESTART_PHASE',
    defaultValue: 'prepare',
  );
  testWidgets('actual persisted backup recovery: $phase', (tester) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final db = container.read(databaseProvider);
    final preferences = container.read(preferencesProvider);
    const key = 'acceptance.backup.recovery';
    final record = <String, Object?>{
      'phase': phase,
      'at': DateTime.now().toUtc().toIso8601String(),
    };
    if (phase == 'prepare') {
      await preferences.set(key, 'before');
      await preferences.flush();
      await BackupImportRecovery.begin(db, {key: 'before'}, {});
      await preferences.set(key, 'interrupted');
      await preferences.flush();
      expect(await db.select(db.backupImportJournals).get(), hasLength(1));
      record['status'] = 'durable pending journal; restart required';
    } else {
      expect(phase, 'resume');
      expect(preferences.get<String>(key), 'before');
      expect(await db.select(db.backupImportJournals).get(), isEmpty);
      record['status'] = 'startup recovered prior setting before UI';
      record['cachedChapterCount'] =
          (await db.select(db.chapters).get()).length;
    }
    final dir = await getApplicationDocumentsDirectory();
    await File('${dir.path}/backup-restart-$phase.json')
        .writeAsString(jsonEncode(record), flush: true);
    // ignore: avoid_print
    print('BACKUP_RESTART_EVIDENCE ${jsonEncode(record)}');
  });
}
