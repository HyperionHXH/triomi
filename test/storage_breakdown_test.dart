import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:triomi/core/storage/cover_store.dart';
import 'package:triomi/features/settings/cache_management_service.dart';

import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('support breakdown identifies update duplicates without counting them twice', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'storage-breakdown-',
    );
    final root = Directory(await temporary.resolveSymbolicLinks());
    final database = openTestDatabase();
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final files = <String, int>{
      'app-update/incoming/release.apk': 11,
      'app-update/install/verified.apk': 13,
      'app-update/metadata.json': 17,
      'mihon-desktop/runtime/runtime.jar': 19,
      'mihon-extensions/installed/extension.apk': 23,
      'retained/database.sqlite': 29,
    };
    for (final entry in files.entries) {
      final file = File(p.join(root.path, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List.filled(entry.value, 1));
    }
    final service = CacheManagementService(
      database: database,
      covers: CoverStore(Directory(p.join(root.path, 'covers'))),
      supportDirectory: root,
      browserPlatform: 'linux',
      browserRoots: () async => [],
    );
    final summary = await service.storageSummary();
    expect(summary.supportBytes, 112);
    expect(summary.updateBytes, 41);
    expect(summary.updateIncomingBytes, 11);
    expect(summary.updateInstallBytes, 13);
    expect(summary.managedRuntimeBytes, 19);
    expect(summary.extensionBytes, 23);
    expect(summary.otherSupportBytes, 29);
    for (final entry in files.entries) {
      expect(
        await File(p.join(root.path, entry.key)).length(),
        entry.value,
        reason: 'storage inspection must not clear retained files',
      );
    }
  });
}
