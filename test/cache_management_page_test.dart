import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:triomi/core/backup/backup_artifact_recovery.dart';
import 'package:triomi/core/storage/cover_store.dart';
import 'package:triomi/features/settings/cache_management_page.dart';
import 'package:triomi/features/settings/cache_management_service.dart';

import 'fixtures/test_database.dart';

void main() {
  testWidgets('opening and declining preview preserve covers; explicit confirmation clears only preview', (tester) async {
    final db = openTestDatabase();
    late Directory root;
    late File cover;
    final scanDone = Completer<void>();
    final clearDone = Completer<void>();
    var releases = 0;
    late CacheManagementService service;
    await tester.runAsync(() async {
      final sandbox = await Directory.systemTemp.createTemp('cache-page-');
      root = Directory(await sandbox.resolveSymbolicLinks());
      final covers = await Directory(p.join(root.path, 'covers')).create();
      cover = File(p.join(covers.path, '${'a' * 64}.img'));
      await cover.writeAsBytes([1, 2, 3]);
      service = CacheManagementService(database: db, covers: CoverStore(covers),
        acquireGuard: () async => BackupArtifactLease(() async {
          if (++releases == 1) scanDone.complete();
          if (releases == 2) clearDone.complete();
        }));
    });
    addTearDown(() async {
      await tester.runAsync(() async { await db.close(); await root.delete(recursive: true); });
    });
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: CacheManagementPage(service: service))));
    await _pumpUntil(tester, () => scanDone.isCompleted, 'initial cover scan');
    await tester.pumpAndSettle();
    expect(find.textContaining('1 个 · 3 B'), findsOneWidget);
    expect(await tester.runAsync(cover.exists), isTrue);
    await tester.ensureVisible(find.text('预览并清理恢复封面'));
    await tester.tap(find.text('预览并清理恢复封面'));
    await tester.pumpAndSettle();
    expect(find.text('确认清理恢复封面？'), findsOneWidget);
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(cover.exists), isTrue);
    await tester.tap(find.text('预览并清理恢复封面'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理这批封面'));
    await _pumpUntil(tester, () => clearDone.isCompleted, 'confirmed cover deletion');
    await tester.pumpAndSettle();
    expect(find.textContaining('本批清理完成：删除 1 个'), findsOneWidget);
    expect(await tester.runAsync(cover.exists), isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() complete, String operation) async {
  // pump executes callbacks in FakeAsync even when its caller is runAsync.
  // Let real filesystem completions arrive, then flush FakeAsync between them;
  // never await a lease-release future that itself needs the next pump.
  for (var attempt = 0; attempt < 200 && !complete(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(complete(), isTrue, reason: '$operation must finish within bounded real-I/O pumps');
  await tester.pump();
}
