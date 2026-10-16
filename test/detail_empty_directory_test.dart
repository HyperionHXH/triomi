import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';

/// D94：详情页空目录与加载失败的分离断言。
///
/// - 请求成功但目录为空（如该来源还没有中文章节）→
///   「当前中文目录为空」+ 搜索其他作品入口；不伪造章节；
/// - 目录请求失败 → 带来源名的错误与重试，**不**显示成功空态文案。
void main() {
  const item = MediaItem(
    sourceId: 'd94-source',
    remoteId: '1',
    type: MediaType.manga,
    title: '无中文目录的作品',
  );

  Future<void> pumpDetail(WidgetTester tester, ContentSource source) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(
            AppDatabase.forTesting(NativeDatabase.memory()),
          ),
          sourcesProvider.overrideWith(() => StubSources(snapshotOf(source))),
          sourceHttpClientProvider.overrideWithValue(
            FakeHttpClient(
              (_) async => const SourceResponse(statusCode: 200, body: ''),
            ),
          ),
        ],
        child: const MaterialApp(home: DetailPage(item: item)),
      ),
    );
    for (var index = 0; index < 10; index++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('停用来源：缓存目录可读且不再请求来源详情', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final library = LibraryRepository(db);
    await library.cacheItem(item);
    await library.saveChapters(
      itemSourceId: item.sourceId,
      itemRemoteId: item.remoteId,
      chapters: const [
        Chapter(sourceId: 'd94-source', remoteId: 'cached', title: '本地缓存章节'),
      ],
    );
    final source = _CountingSource();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sourcesProvider.overrideWith(
            () => StubSources(
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
        child: const MaterialApp(home: DetailPage(item: item)),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(source.requests, 0);
    expect(find.text('本地缓存章节'), findsOneWidget);
    expect(find.textContaining('显示本机缓存'), findsOneWidget);
  });

  testWidgets('停用且无缓存：明确拒绝且零请求，启用后重新加载恢复', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final source = _CountingSource();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sourcesProvider.overrideWith(
          () => StubSources(
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
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DetailPage(item: item)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('该来源已停用'), findsWidgets);
    expect(source.requests, 0);
    expect(find.textContaining('显示本机缓存'), findsNothing);
    final sources = container.read(sourcesProvider.notifier) as StubSources;
    sources.snapshot = snapshotOf(source);
    await sources.refresh();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新补全资料'));
    await tester.pumpAndSettle();
    expect(find.text('当前中文目录为空'), findsOneWidget);
    expect(find.textContaining('该来源已停用'), findsNothing);
    expect(source.requests, 2);
  });

  testWidgets('成功但无中文章节：明确空目录说明 + 搜索其他作品，不伪造章节', (tester) async {
    await pumpDetail(tester, _EmptyCatalogSource());

    expect(find.text('当前中文目录为空'), findsOneWidget);
    expect(find.textContaining('暂时没有这本作品的中文章节'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '搜索其他作品'), findsOneWidget);
    // 不把成功空态说成失败，也不出现伪造的章节行。
    expect(find.textContaining('加载失败'), findsNothing);
  });

  testWidgets('目录请求失败：显示带来源的错误与重试，不被空态吞掉', (tester) async {
    await pumpDetail(tester, _BrokenCatalogSource());

    // 错误卡可见，带来源名（SourceRegistry.describeError 的口径；
    // 来源名同时出现在头部与错误卡，断言至少一处即可）。
    expect(find.textContaining('D94 夹具源'), findsWidgets);
    expect(find.text('重试目录'), findsOneWidget);
    // 失败绝不能伪装成「成功但空」。
    expect(find.text('当前中文目录为空'), findsNothing);
    expect(find.text('未能取得章节目录（原因见上方错误）。'), findsOneWidget);
    expect(
      find.textContaining('搜索其他作品'),
      findsNothing,
      reason: '失败态不给「去搜索别的作品」的误导入口',
    );
  });
}

class StubSources extends SourceRegistryController {
  StubSources(this.snapshot);

  SourceRegistrySnapshot snapshot;

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

SourceRegistrySnapshot snapshotOf(ContentSource source) =>
    SourceRegistrySnapshot(
      entries: <SourceEntry>[
        SourceEntry(
          descriptor: source.descriptor,
          source: source,
          enabled: true,
        ),
      ],
      failures: const <SourceFailure>[],
    );

/// detail 成功但目录为空（来源还没有中文章节的场景）。
class _EmptyCatalogSource implements DetailProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'd94-source',
    name: 'D94 夹具源',
    type: MediaType.manga,
    kind: SourceKind.builtin,
    capabilities: {SourceCapability.search, SourceCapability.detail},
  );

  @override
  bool get isReady => true;

  @override
  Future<MediaItem> detail(MediaItem item) async => item;

  @override
  Future<List<Chapter>> chapters(MediaItem item) async => const <Chapter>[];
}

/// 目录请求直接失败（解析/HTTP 错误语义）。
class _BrokenCatalogSource implements DetailProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'd94-source',
    name: 'D94 夹具源',
    type: MediaType.manga,
    kind: SourceKind.builtin,
    capabilities: {SourceCapability.search, SourceCapability.detail},
  );

  @override
  bool get isReady => true;

  @override
  Future<MediaItem> detail(MediaItem item) async => item;

  @override
  Future<List<Chapter>> chapters(MediaItem item) async =>
      throw const SourceException(
        sourceId: 'd94-source',
        type: SourceErrorType.parse,
        message: '目录解析失败',
      );
}

class _CountingSource extends _EmptyCatalogSource {
  int requests = 0;
  @override
  Future<MediaItem> detail(MediaItem item) async {
    requests++;
    return item;
  }

  @override
  Future<List<Chapter>> chapters(MediaItem item) async {
    requests++;
    return const [];
  }
}
