import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../storage/preferences.dart';

/// SQLite owns the commit decision for an import spanning SQLite and Hive.
/// A surviving record is retryable even when immediate compensation failed.
abstract final class BackupImportRecovery {
  static Future<void> begin(
    AppDatabase database,
    Map<String, Object?> previous,
    Set<String> missing,
  ) async {
    // The singleton primary key also refuses concurrent imports before either
    // can mutate settings. Journals never contain incoming secrets.
    await database
        .into(database.backupImportJournals)
        .insert(
          BackupImportJournalsCompanion.insert(
            id: const Value(1),
            previousValuesJson: jsonEncode(previous),
            missingKeysJson: jsonEncode(missing.toList()),
          ),
        );
  }

  /// Call only after settings have been flushed, inside the data transaction.
  static Future<void> commit(AppDatabase database) =>
      database.delete(database.backupImportJournals).go();

  /// Must run before the app exposes settings to UI. Keep the record if any
  /// restore/flush fails, so the next launch can retry the exact old values.
  static Future<bool> recover(
    AppDatabase database,
    Preferences preferences,
  ) async {
    final row = await database
        .select(database.backupImportJournals)
        .getSingleOrNull();
    if (row == null) return false;
    final previous = (jsonDecode(row.previousValuesJson) as Map)
        .cast<String, Object?>();
    final missing = (jsonDecode(row.missingKeysJson) as List)
        .cast<String>()
        .toSet();
    await preferences.restoreSubset(previous, missing);
    await preferences.flush();
    await commit(database);
    return true;
  }
}
