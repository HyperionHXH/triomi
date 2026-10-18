import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/search/search_page.dart';
import 'package:triomi/features/sources/sources_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// D95：小说入口与账号状态。
///
/// - 匿名可用的来源（LK 语义）不被 UI 挡住：结果正常渲染，无登录拦截；
/// - 认证失败（LNS 语义：匿名 GetBookList 返回 unauthorized）→
///   该来源给正确的账号入口，保留其他来源结果与本地书架；
/// - 非认证错误 / 无账号能力的来源不给误导性登录入口；
/// - 打开账号对话框后取消 → 不删收藏、不触发登出清理。
void main() {
  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  testWidgets('多源部分失败：LNS 认证错误给账号入口，LK 匿名结果照常可用', (tester) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(
            AppDatabase.forTesting(NativeDatabase.memory()),
          ),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourceHttpClientProvider.overrideWithValue(
            FakeHttpClient(
              (_) async => const SourceResponse(statusCode: 200, body: ''),
            ),
          ),
          sourcesProvider.overrideWith(
            () => StubSources(
              _snapshotOf(<ContentSource>[
                _NovelSource(
                  id: 'light-novel-kingdom',
                  name: '轻之国度',
                  failure: null,
                  items: const <MediaItem>[
                    MediaItem(
                      sourceId: 'light-novel-kingdom',
                      remoteId: '33139',
                      type: MediaType.novel,
                      title: '匿名可读的小说',
                    ),
                  ],
                ),
                _NovelSource(
                  id: 'light-novel-shelf',
                  name: '轻书架',
                  failure: const SourceException(
                    sourceId: 'light-novel-shelf',
                    type: SourceErrorType.auth,
                    message: "Failed to invoke 'GetBookList' because user is unauthorized",
                  ),
                ),
              ]),
            ),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: GoRouter(
            initialLocation: '/',
            routes: <RouteBase>[
              GoRoute(
                path: '/',
                builder: (context, state) =>
                    const SearchPage(type: MediaType.novel),
              ),
              GoRoute(
                path: '/lns-account',
                builder: (context, state) =>
                    const Scaffold(body: Center(child: Text('LNS 账号页'))),
              ),
            ],
          ),
        ),
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField), '小说');
    await tester.tap(find.byTooltip('搜索'));
    await settle(tester);

    // 匿名来源不被挡：结果正常显示，没有登录入口。
    expect(find.text('匿名可读的小说'), findsOneWidget);

    // 认证失败：具体错误 + 正确的账号入口（不是来源管理页）。

    await tester.tap(find.text('前往登录'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('LNS 账号页'), findsOneWidget, reason: '去正确的账号页');
  });

  testWidgets('非认证错误与无账号能力的来源不给登录入口', (tester) async {
    Widget build(List<ContentSource> sources) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(
          AppDatabase.forTesting(NativeDatabase.memory()),
        ),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        sourcesProvider.overrideWith(() => StubSources(_snapshotOf(sources))),
      ],
      child: const MaterialApp(home: SearchPage(type: MediaType.novel)),
    );
    await tester.pumpWidget(
      build(<ContentSource>[
        _NovelSource(
          id: 'net-broken',
          name: '断网源',
          failure: const SourceException(
            sourceId: 'net-broken',
            type: SourceErrorType.network,
            message: 'HTTP 503',
          ),
        ),
        // 规则源没有账号体系：不实现 AccountProvider，即使报 auth 类错误
        // 也不该给「登录」入口（没有可去的地方）。
        _RuleSearchSource(
          id: 'rule-auth',
          name: '规则源',
          failure: const SourceException(
            sourceId: 'rule-auth',
            type: SourceErrorType.auth,
            message: '需要 Cookie',
          ),
        ),
      ]),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField), '词');
    await tester.tap(find.byTooltip('搜索'));
    await settle(tester);

    expect(find.textContaining('HTTP 503'), findsOneWidget);
    expect(find.textContaining('需要 Cookie'), findsOneWidget);
    final loginTexts = tester
        .widgetList<Text>(find.byType(Text))
        .where((widget) => (widget.data ?? '').startsWith('登录'))
        .map((widget) => widget.data)
        .toList();
    expect(loginTexts, isEmpty, reason: '网络错误或无账号能力的来源不显示登录入口');
  });

  testWidgets('取消账号对话框不删收藏也不触发登出', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(db.close);
      await tester.pump(const Duration(milliseconds: 1));
    });
    final repository = LibraryRepository(db);
    await repository.addToLibrary(
      const MediaItem(
        sourceId: 'light-novel-shelf',
        remoteId: '7',
        type: MediaType.novel,
        title: '轻书架收藏',
      ),
    );

    var logoutCalled = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(
            FakeHttpClient(
              (_) async => const SourceResponse(statusCode: 200, body: ''),
            ),
          ),
          sourcesProvider.overrideWith(
            () => StubSources(
              _snapshotOf(<ContentSource>[
                _NovelSource(
                  id: 'light-novel-shelf',
                  name: '轻书架',
                  onLogout: () => logoutCalled = true,
                ),
              ]),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: SourcesPage(initialType: MediaType.novel)),
        ),
      ),
    );
    await settle(tester);

    // 打开账号对话框。
    await tester.tap(find.widgetWithText(TextButton, '站点账号'));
    await settle(tester);
    expect(find.textContaining('· 账号'), findsOneWidget);

    // 点对话框外的 scrim 取消（不填账号、不点登录）。
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    expect(find.textContaining('· 账号'), findsNothing);

    expect(logoutCalled, isFalse, reason: '取消不触发登出/清理');
    expect(
      await repository.isInLibrary('light-novel-shelf', '7'),
      isTrue,
      reason: '取消登录不删收藏',
    );
  });
}

class StubSources extends SourceRegistryController {
  StubSources(this.snapshot);

  final SourceRegistrySnapshot snapshot;

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

SourceRegistrySnapshot _snapshotOf(List<ContentSource> sources) =>
    SourceRegistrySnapshot(
      entries: <SourceEntry>[
        for (final source in sources)
          SourceEntry(
            descriptor: source.descriptor,
            source: source,
            enabled: true,
          ),
      ],
      failures: const <SourceFailure>[],
    );

/// 内置小说来源替身：默认带账号能力（LK/LNS 语义），可编程失败与登出记录。
class _NovelSource implements ContentSource, SearchProvider, AccountProvider {
  _NovelSource({
    required this.id,
    required this.name,
    this.failure,
    this.items = const <MediaItem>[],
    this.onLogout,
  });

  final String id;
  final String name;
  final SourceException? failure;
  final List<MediaItem> items;
  final void Function()? onLogout;

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: name,
    type: MediaType.novel,
    kind: SourceKind.builtin,
    requireLogin: false,
    capabilities: const {
      SourceCapability.search,
      SourceCapability.detail,
      SourceCapability.account,
    },
  );

  @override
  bool get isReady => true;

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    final failure = this.failure;
    if (failure != null) throw failure;
    return items;
  }

  @override
  bool get isLoggedIn => false;

  @override
  Future<void> restoreSession() async {}

  @override
  Future<void> login(String account, String password) async {}

  @override
  Future<void> logout() async => onLogout?.call();
}

/// 规则搜索源替身：没有账号体系（不实现 AccountProvider）。
class _RuleSearchSource implements ContentSource, SearchProvider {
  _RuleSearchSource({
    required this.id,
    required this.name,
    required this.failure,
  });

  final String id;
  final String name;
  final SourceException failure;

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: name,
    type: MediaType.novel,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.search, SourceCapability.detail},
  );

  @override
  bool get isReady => true;

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async =>
      throw failure;
}
