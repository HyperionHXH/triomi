import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/manga/manga_extension_details_page.dart';
import 'package:triomi/features/manga/manga_item_actions.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _Sources extends SourceRegistryController {
  _Sources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

void main() {
  testWidgets(
    'extension details separates each source and factual settings capability',
    (tester) async {
      const package = 'extension.example';
      final preferences = memoryPreferences();
      await preferences.set('mihon.enabledPackages', [package]);
      await preferences.set('mihon.hostStatus', {
        package: {'ok': true, 'versionCode': 1},
      });
      final entries = [
        for (final (id, configurable) in [
          ('configured', true),
          ('no-settings', false),
        ])
          () {
            final source = MihonSource(
              packageName: package,
              hostSourceId: id,
              name: id,
              lang: 'zh',
              enabled: true,
              apkPath: null,
              versionCode: 1,
              signerSha256: null,
              isConfigurable: configurable,
            );
            return SourceEntry(
              descriptor: source.descriptor,
              source: source,
              enabled: true,
            );
          }(),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            sourcesProvider.overrideWith(
              () => _Sources(
                SourceRegistrySnapshot(entries: entries, failures: const []),
              ),
            ),
          ],
          child: const MaterialApp(
            home: MangaExtensionDetailsPage(packageName: package),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('configured · zh'), findsOneWidget);
      expect(find.text('no-settings · zh'), findsOneWidget);
      expect(find.text('来源设置'), findsNWidgets(2));
      expect(find.text('此来源没有提供可配置设置'), findsOneWidget);
      await tester.ensureVisible(find.text('来源设置').last);
      await tester.tap(find.text('来源设置').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('此来源没有提供可配置设置'), findsNWidgets(2));
      expect(find.byType(MangaExtensionDetailsPage), findsOneWidget);
      expect(find.text('规则与来源设置'), findsNothing);
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            sourcesProvider.overrideWith(
              () => _Sources(
                SourceRegistrySnapshot(entries: entries, failures: const []),
              ),
            ),
          ],
          child: const MaterialApp(
            home: MangaExtensionDetailsPage(packageName: package),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('应用内网页 / 会话验证'), findsNothing);
      expect(find.text('来源设置'), findsNWidgets(2));
      expect(find.text('外部浏览器'), findsNWidgets(2));

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            sourcesProvider.overrideWith(
              () => _Sources(
                SourceRegistrySnapshot(entries: entries, failures: const []),
              ),
            ),
          ],
          child: const MaterialApp(
            home: MangaExtensionDetailsPage(packageName: package),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('应用内网页 / 会话验证'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'disabled extension settings reports the guard without invoking plugin code',
    (tester) async {
      const package = 'extension.disabled';
      final preferences = memoryPreferences();
      final source = MihonSource(
        packageName: package,
        hostSourceId: '1',
        name: 'Disabled',
        lang: 'zh',
        enabled: false,
        apkPath: null,
        versionCode: 1,
        signerSha256: null,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            sourcesProvider.overrideWith(
              () => _Sources(
                SourceRegistrySnapshot(
                  entries: [
                    SourceEntry(
                      descriptor: source.descriptor,
                      source: source,
                      enabled: false,
                    ),
                  ],
                  failures: const [],
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            home: MangaExtensionDetailsPage(packageName: package),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('来源设置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('此来源已停用；请先'), findsOneWidget);
      expect(find.text('规则与来源设置'), findsNothing);
    },
  );

  testWidgets(
    'relative APK manga URL exposes browser action but disabled host never executes',
    (tester) async {
      final db = openTestDatabase();
      final source = MihonSource(
        packageName: 'extension.disabled',
        hostSourceId: '1',
        name: 'Disabled',
        lang: 'zh',
        enabled: false,
        apkPath: null,
        versionCode: 1,
        signerSha256: null,
      );
      final item = MediaItem(
        sourceId: source.descriptor.id,
        remoteId: '/manga/relative-id',
        type: MediaType.manga,
        title: 'Relative APK manga',
        url: '/manga/relative-id',
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await db.close();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            sourcesProvider.overrideWith(
              () => _Sources(
                SourceRegistrySnapshot(
                  entries: [
                    SourceEntry(
                      descriptor: source.descriptor,
                      source: source,
                      enabled: false,
                    ),
                  ],
                  failures: const [],
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => showMangaItemActions(context, ref, item),
                  child: const Text('作品操作'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('作品操作'));
      await tester.pumpAndSettle();
      expect(find.text('在浏览器打开'), findsOneWidget);
      await tester.tap(find.text('在浏览器打开'));
      await tester.pumpAndSettle();
      expect(find.textContaining('此插件来源未启用、未受信任或宿主不可用'), findsOneWidget);
    },
  );
}
