import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/features/detail/anime_source_sheet.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';

import 'fixtures/test_database.dart';

const item = MediaItem(
  sourceId: 'metadata',
  remoteId: '1',
  type: MediaType.anime,
  title: '原名',
  url: 'https://example.test/1',
);

class TestSource implements SearchProvider, DetailProvider, ContentProvider {
  TestSource(this.id, this.searcher, {this.playable = true});
  final String id;
  final Future<List<MediaItem>> Function(String) searcher;
  final bool playable;
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: id,
    type: MediaType.anime,
    kind: SourceKind.plugin,
    capabilities: {
      SourceCapability.search,
      SourceCapability.detail,
      if (playable) SourceCapability.content,
    },
  );
  @override
  bool get isReady => true;
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) =>
      searcher(keyword);
  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => [];
  @override
  Future<ChapterContent> content(Chapter chapter) => throw UnimplementedError();
  MediaItem result(String title) => MediaItem(
    sourceId: id,
    remoteId: title,
    type: MediaType.anime,
    title: title,
    url: 'https://example.test/$title',
  );
}

class StubSources extends SourceRegistryController {
  StubSources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

late AppDatabase testDb;

Widget harness(List<(TestSource, bool)> sources) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(testDb),
    sourcesProvider.overrideWith(
      () => StubSources(
        SourceRegistrySnapshot(
          entries: [
            for (final (source, enabled) in sources)
              SourceEntry(
                descriptor: source.descriptor,
                source: source,
                enabled: enabled,
              ),
          ],
          failures: const [],
        ),
      ),
    ),
  ],
  child: const MaterialApp(
    home: Scaffold(body: AnimeSourceSheet(item: item)),
  ),
);

void main() {
  setUp(() => testDb = openTestDatabase());
  tearDown(() async {
    await testDb.close();
  });
  testWidgets('只搜索已启用播放来源，单站失败不丢失其他站结果', (tester) async {
    late TestSource good;
    good = TestSource('可用站', (_) async => [good.result('匹配作品')]);
    var excludedRequests = 0;
    final disabled = TestSource('停用站', (_) async {
      excludedRequests++;
      return [];
    });
    final metadata = TestSource('资料站', (_) async {
      excludedRequests++;
      return [];
    }, playable: false);
    final failed = TestSource('失败站', (_) async => throw StateError('offline'));
    await tester.pumpWidget(
      harness([
        (good, true),
        (failed, true),
        (disabled, false),
        (metadata, true),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('匹配作品'), findsOneWidget);
    expect(find.text('搜索失败，请重试'), findsOneWidget);
    expect(excludedRequests, 0);
    expect(find.text('停用站'), findsNothing);
    expect(find.text('资料站'), findsNothing);
  });

  testWidgets('候选需人工确认，取消不保存，确认保持资料身份', (tester) async {
    late TestSource source;
    source = TestSource('站点', (_) async => [source.result('第二季候选')]);
    await tester.pumpWidget(harness([(source, true)]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二季候选'));
    await tester.pumpAndSettle();
    expect(find.text('确认作品关联'), findsOneWidget);
    final repo = AnimeIdentityRepository(testDb);
    expect(await repo.subjectFor(source.result('第二季候选')), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await repo.subjectFor(source.result('第二季候选')), isNull);
    await tester.tap(find.text('第二季候选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认关联'));
    await tester.pumpAndSettle();
    expect(
      (await repo.subjectFor(source.result('第二季候选')))!.remoteId,
      item.remoteId,
    );
  });

  testWidgets('改名搜索忽略旧请求的晚到结果', (tester) async {
    final old = Completer<List<MediaItem>>();
    late TestSource source;
    source = TestSource(
      '站点',
      (query) =>
          query == '原名' ? old.future : Future.value([source.result('新匹配')]),
    );
    await tester.pumpWidget(harness([(source, true)]));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '别名');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('新匹配'), findsOneWidget);
    old.complete([source.result('过期匹配')]);
    await tester.pumpAndSettle();
    expect(find.text('过期匹配'), findsNothing);
    expect(find.text('新匹配'), findsOneWidget);
  });

  testWidgets('每站前三条和展开收起保留所有候选', (tester) async {
    late TestSource source;
    source = TestSource(
      '站点',
      (_) async => [for (var i = 1; i <= 6; i++) source.result('候选$i')],
    );
    await tester.pumpWidget(harness([(source, true)]));
    await tester.pumpAndSettle();
    expect(find.text('候选1'), findsOneWidget);
    expect(find.text('候选4'), findsNothing);
    await tester.ensureVisible(find.text('展开全部 6 个结果'));
    await tester.tap(find.text('展开全部 6 个结果'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('候选6'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('候选6'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('收起结果'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('收起结果'));
    await tester.pumpAndSettle();
    expect(find.text('候选4'), findsNothing);
  });
}
