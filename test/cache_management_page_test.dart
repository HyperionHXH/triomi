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
  testWidgets(
    'opening and declining preview preserve covers; explicit confirmation clears only preview',
    (tester) async {
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
        service = CacheManagementService(
          database: db,
          covers: CoverStore(covers),
          supportDirectory: root,
          browserPlatform: 'linux',
          browserRoots: () async => const <Directory>[],
          acquireGuard: () async => BackupArtifactLease(() async {
            if (++releases == 1) {
              scanDone.complete();
            }
            if (releases == 2) {
              clearDone.complete();
            }
          }),
        );
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await db.close();
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: CacheManagementPage(service: service)),
        ),
      );
      await _pumpUntil(
        tester,
        () => scanDone.isCompleted,
        'initial cover scan',
      );
      await _waitForIdle(tester, 'initial storage aggregate');
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
      await _pumpUntil(
        tester,
        () => clearDone.isCompleted,
        'confirmed cover deletion',
      );
      await _waitForIdle(tester, 'cover deletion result');
      await tester.pumpAndSettle();
      await _expectMessage(tester, '本批清理完成：删除 1 个（3 B）');
      expect(await tester.runAsync(cover.exists), isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'HTTP clear is confirmed and reports measured remaining bytes while preserving sessions',
    (tester) async {
      final db = openTestDatabase();
      late Directory root;
      late File response;
      late File cookie;
      late CacheManagementService service;
      var scans = 0;
      var clears = 0;
      await tester.runAsync(() async {
        root = Directory(
          await (await Directory.systemTemp.createTemp('http-cache-page-'))
              .resolveSymbolicLinks(),
        );
        final support = await Directory(p.join(root.path, 'support')).create();
        final profile = Directory(p.join(support.path, 'video-webview'));
        final cache = await Directory(p.join(profile.path, 'Default', 'Cache'))
            .create(recursive: true);
        response = await File(p.join(cache.path, 'response'))
            .writeAsBytes([1, 2, 3]);
        cookie = await File(p.join(profile.path, 'Cookies')).writeAsBytes([9]);
        final covers = await Directory(p.join(root.path, 'covers')).create();
        service = CacheManagementService(
          database: db,
          covers: CoverStore(covers),
          supportDirectory: support,
          browserPlatform: 'windows',
          acquireGuard: () async => BackupArtifactLease(() async {
            scans++;
          }),
          clearBrowserProfile: (_) async {
            clears++;
            await response.delete();
          },
        );
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await db.close();
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: CacheManagementPage(service: service)),
        ),
      );
      await _pumpUntil(tester, () => scans == 1, 'cover preview');
      final button = find.text('预览并清理网页 HTTP 缓存');
      await _pumpUntil(tester, () {
        final widgets = tester.widgetList<TextButton>(
          find.ancestor(of: button, matching: find.byType(TextButton)),
        );
        return widgets.isNotEmpty && widgets.single.onPressed != null;
      }, 'HTTP storage aggregate');
      await _waitForIdle(tester, 'initial HTTP storage aggregate');
      expect(find.textContaining('3 B · 1 个应用内浏览器存储'), findsOneWidget);
      expect(clears, 0);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('清理网页 HTTP 缓存？'), findsOneWidget);
      await tester.tap(find.text('保留'));
      await tester.pumpAndSettle();
      expect(clears, 0);
      expect(await tester.runAsync(response.exists), isTrue);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理 HTTP 缓存'));
      await _pumpUntil(tester, () => clears == 1, 'HTTP clear');
      await _waitForIdle(tester, 'HTTP post-clear aggregate');
      await _expectMessage(tester, '网页 HTTP 缓存清理：实测减少 3 B，剩余 0 B；失败 0 项。');
      expect(await tester.runAsync(cookie.readAsBytes), [9]);
      expect(await tester.runAsync(response.exists), isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'cancelling the storage phase preserves covers and hides incomplete totals',
    (tester) async {
      final db = openTestDatabase();
      final roots = Completer<List<Directory>>();
      var discoveringStorage = false;
      late Directory root;
      late File cover;
      late CacheManagementService service;
      await tester.runAsync(() async {
        root = Directory(
          await (await Directory.systemTemp.createTemp('cancel-cache-page-'))
              .resolveSymbolicLinks(),
        );
        final covers = await Directory(p.join(root.path, 'covers')).create();
        cover = await File(p.join(covers.path, '${'a' * 64}.img'))
            .writeAsBytes([1, 2, 3]);
        service = CacheManagementService(
          database: db,
          covers: CoverStore(covers),
          supportDirectory: root,
          browserPlatform: 'windows',
          browserRoots: () {
            discoveringStorage = true;
            return roots.future;
          },
          acquireGuard: () async => BackupArtifactLease(() async {}),
        );
      });
      addTearDown(() async {
        if (!roots.isCompleted) {
          roots.complete([]);
        }
        await tester.runAsync(() async {
          await db.close();
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: CacheManagementPage(service: service)),
        ),
      );
      await _pumpUntil(
        tester,
        () => discoveringStorage,
        'storage discovery after cover preview',
      );
      expect(find.text('正在统计存储用量'), findsOneWidget);
      expect(find.text('正在扫描封面'), findsNothing);
      await tester.tap(find.text('取消'));
      roots.complete([root]);
      await _waitForIdle(tester, 'cancelled storage aggregate');
      await _expectMessage(tester, '扫描已取消；不完整的缓存用量未显示为完整统计。');
      expect(find.text('正在统计存储用量'), findsNothing);
      final httpAction = find.text('预览并清理网页 HTTP 缓存');
      await tester.scrollUntilVisible(
        httpAction,
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final httpButton = tester.widget<TextButton>(
        find.ancestor(of: httpAction, matching: find.byType(TextButton)),
      );
      expect(httpButton.onPressed, isNull);
      expect(find.text('尚未完成统计'), findsWidgets);
      expect(await tester.runAsync(cover.readAsBytes), [1, 2, 3]);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Future<void> _waitForIdle(WidgetTester tester, String operation) => _pumpUntil(
  tester,
  () => tester
      .widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '重新扫描',
        ),
      )
      .onPressed != null,
  operation,
);

Future<void> _expectMessage(WidgetTester tester, String text) async {
  final message = find.byWidgetPredicate(
    (widget) =>
        widget is SelectableText && (widget.data?.contains(text) ?? false),
    description: 'selectable result containing "$text"',
  );
  // Results are inserted above the action the user just tapped. Bring that
  // real, lazily-built result into view instead of timing out on an unseen row.
  await tester.scrollUntilVisible(
    message,
    -300,
    scrollable: find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  expect(message, findsOneWidget);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() complete,
  String operation,
) async {
  // pump executes callbacks in FakeAsync even when its caller is runAsync.
  // Let real filesystem completions arrive, then flush FakeAsync between them;
  // never await a lease-release future that itself needs the next pump.
  for (var attempt = 0; attempt < 200 && !complete(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(
    complete(),
    isTrue,
    reason: '$operation must finish within bounded real-I/O pumps',
  );
  await tester.pump();
}
