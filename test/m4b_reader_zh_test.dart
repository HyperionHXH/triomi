import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/text/zh_converter.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';

/// 固定正文的最小小说来源。
class _StubNovelSource implements ContentProvider {
  @override
  Future<ChapterContent> content(Chapter chapter) async =>
      const ChapterContent(text: '简体测试段落：小说阅读器与字体。');

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'stub-novel',
    name: '测试小说源',
    type: MediaType.novel,
    kind: SourceKind.builtin,
    lang: 'zh',
    capabilities: {SourceCapability.content},
  );

  @override
  bool get isReady => true;
}

/// 注入固定来源的注册表替身。
class _StubSourcesController extends SourceRegistryController {
  _StubSourcesController(this._source);

  final ContentSource _source;

  @override
  Future<SourceRegistrySnapshot> build() async {
    return SourceRegistrySnapshot(
      entries: [
        SourceEntry(
          descriptor: _source.descriptor,
          source: _source,
          enabled: true,
        ),
      ],
      failures: const [],
    );
  }
}

/// 纯内存 Box：FakeAsync 区里不能有任何真实 IO（Hive 写盘会永久挂起）。
class _MemBox implements Box<dynamic> {
  final _map = <dynamic, dynamic>{};

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) => _map[key] ?? defaultValue;

  @override
  Future<void> put(dynamic key, dynamic value) async => _map[key] = value;

  @override
  Future<void> delete(dynamic key) async => _map.remove(key);

  @override
  Future<int> clear() async {
    final count = _map.length;
    _map.clear();
    return count;
  }

  @override
  bool containsKey(dynamic key) => _map.containsKey(key);

  @override
  Iterable<dynamic> get keys => _map.keys;

  @override
  Iterable<dynamic> get values => _map.values;

  @override
  bool get isOpen => true;

  @override
  String get name => 'settings';

  @override
  String? get path => null;

  @override
  Stream<BoxEvent> watch({dynamic key}) => const Stream<BoxEvent>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('阅读设置里切换繁简后，正文当场重转换', (tester) async {
    final preferences = Preferences(_MemBox());
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // OpenCC 字表是真实文件 IO：FakeAsync 区里必须用 runAsync 预热全局缓存，
    // 否则阅读器内 await ZhConverter.instance() 会挂死。
    await tester.runAsync(ZhConverter.instance);

    const item = MediaItem(
      sourceId: 'stub-novel',
      remoteId: '1',
      type: MediaType.novel,
      title: '繁简测试书',
    );
    const chapters = [
      Chapter(sourceId: 'stub-novel', remoteId: '1', title: '第 1 章'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          databaseProvider.overrideWithValue(db),
          sourcesProvider.overrideWith(
            () => _StubSourcesController(_StubNovelSource()),
          ),
        ],
        child: MaterialApp(
          home: NovelReaderPage(
            args: NovelReaderArgs(
              item: item,
              chapters: chapters,
              initialIndex: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));

    // 简体正文已渲染。
    expect(find.textContaining('简体测试段落'), findsOneWidget);

    // 打开阅读设置（默认 chrome 可见）。
    await tester.tap(find.byIcon(Icons.text_format));
    await tester.pumpAndSettle();

    // '简→繁' 在 sheet 的 SingleChildScrollView 下方可视区外，先滚到可见。
    await tester.scrollUntilVisible(find.text('简→繁'), 160);
    await tester.pumpAndSettle();

    // 选「简→繁」。
    await tester.tap(find.text('简→繁'));
    await tester.pumpAndSettle();

    // 正文当场变成繁体（设置变更 → 重转换 → 重新分页）。
    expect(find.textContaining('簡體測試段落'), findsOneWidget);
    expect(find.textContaining('简体测试段落'), findsNothing);
  });
}
