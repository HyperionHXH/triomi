import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/novel/data/lns/lns_auth.dart';
import 'package:triomi/features/novel/data/lns/lns_gateway.dart';
import 'package:triomi/features/novel/data/lns/lns_hub_connection.dart';
import 'package:triomi/features/novel/data/lns/lns_source.dart';
import 'package:triomi/features/novel/lns/lns_account_page.dart';
import 'package:triomi/features/novel/remote_shelf_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

MediaItem book(String sourceId, String title) => MediaItem(
  sourceId: sourceId,
  remoteId: '1',
  type: MediaType.novel,
  title: title,
  author: '作者甲',
);

/// 远端书架替身：可注入登录状态与书目。
class FakeShelfSource implements RemoteShelfProvider {
  FakeShelfSource({
    required this.id,
    required this.name,
    this.loggedIn = true,
    this.books = const <MediaItem>[],
  });

  final String id;
  final String name;
  bool loggedIn;
  List<MediaItem> books;
  int shelfCalls = 0;

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: name,
    type: MediaType.novel,
    kind: SourceKind.builtin,
    capabilities: const <SourceCapability>{
      SourceCapability.account,
      SourceCapability.remoteShelf,
    },
  );

  @override
  bool get isReady => true;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  Future<void> restoreSession() async {}

  @override
  Future<void> login(String account, String password) async {}

  @override
  Future<void> logout() async {}

  @override
  Future<List<MediaItem>> remoteShelf() async {
    shelfCalls += 1;
    return books;
  }

  @override
  Future<void> setInRemoteShelf(MediaItem item, bool add) async {}
}

/// 声明了远端书架能力但没实现契约的来源（不应出现在切换条里）。
class CapabilityOnlySource implements ContentSource {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'cap-only',
    name: '只有能力没有实现',
    type: MediaType.novel,
    kind: SourceKind.plugin,
    capabilities: <SourceCapability>{SourceCapability.remoteShelf},
  );

  @override
  bool get isReady => true;
}

class StubSources extends SourceRegistryController {
  StubSources(this.snapshot);

  final SourceRegistrySnapshot snapshot;

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

SourceRegistrySnapshot snapshotOf(
  List<ContentSource> sources, {
  Set<String> disabled = const <String>{},
}) => SourceRegistrySnapshot(
  entries: <SourceEntry>[
    for (final source in sources)
      SourceEntry(
        descriptor: source.descriptor,
        source: source,
        enabled: !disabled.contains(source.descriptor.id),
      ),
  ],
  failures: const <SourceFailure>[],
);

Widget harness(SourceRegistrySnapshot snapshot, Widget child) => ProviderScope(
  overrides: [sourcesProvider.overrideWith(() => StubSources(snapshot))],
  child: MaterialApp(theme: AppTheme.light(), home: child),
);

// ---------------------------------------------------------------- LNS 替身

class StubHub implements LnsHubConnection {
  StubHub(this.handler);

  final Future<Object?> Function(String target, Object? params) handler;

  @override
  Future<Object?> invoke(String target, Object? params) =>
      handler(target, params);

  @override
  void reset() {}
}

class FakeTokenStore implements LnsTokenStore {
  FakeTokenStore({this.tokens});

  LnsTokens? tokens;

  @override
  LnsTokens? read() => tokens;

  @override
  Future<void> save(LnsTokens value) async => tokens = value;

  @override
  Future<void> clear() async => tokens = null;
}

Map<Object?, Object?> envelope(Object? response) => <Object?, Object?>{
  'Success': true,
  'Response': response,
};

LnsSource lnsSource({required LnsHubConnection hub, bool loggedIn = true}) {
  final store = FakeTokenStore(
    tokens: loggedIn
        ? const LnsTokens(accessToken: 'access', refreshToken: 'refresh')
        : null,
  );
  final limiter = ShelfRateLimiter(
    maxRequests: 1000,
    sleep: (duration) async {},
  );
  return LnsSource(
    gateway: LnsGateway(connection: hub, limiter: limiter),
    auth: LnsAuth(
      http: FakeHttpClient(
        (request) async => const SourceResponse(statusCode: 200, body: '{}'),
      ),
      limiter: limiter,
      store: store,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('远端书架来源挑选取（能力驱动，不再写死站点）', () {
    test('只保留「已启用 + 声明 remoteShelf + 实现契约」的来源', () {
      final lk = FakeShelfSource(id: 'lk', name: '轻之国度');
      final lns = FakeShelfSource(id: 'lns', name: '轻书架');
      final snapshot = snapshotOf(
        <ContentSource>[lk, lns, CapabilityOnlySource()],
        disabled: <String>{lns.id},
      );

      expect(
        remoteShelfEntries(snapshot).map((entry) => entry.descriptor.id),
        <String>['lk'],
      );

      // 启用后按注册表顺序都出现。
      final enabled = snapshotOf(<ContentSource>[
        lk,
        lns,
        CapabilityOnlySource(),
      ]);
      expect(
        remoteShelfEntries(enabled).map((entry) => entry.descriptor.id),
        <String>['lk', 'lns'],
      );
    });
  });

  group('远端书架页', () {
    testWidgets('单来源已登录：渲染站点收藏，不显示切换条', (tester) async {
      final lk = FakeShelfSource(
        id: 'lk',
        name: '轻之国度',
        books: <MediaItem>[book('lk', '站点收藏甲')],
      );
      await tester.pumpWidget(
        harness(snapshotOf(<ContentSource>[lk]), const RemoteShelfPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('远端书架'), findsOneWidget);
      expect(find.text('站点收藏甲'), findsOneWidget);
      // 只有一个来源时不出现来源切换条。
      expect(find.text('轻之国度'), findsNothing);
      expect(lk.shelfCalls, 1);
    });

    testWidgets('未登录：给出「去登录」引导且不拉取站点收藏', (tester) async {
      final lk = FakeShelfSource(id: 'lk', name: '轻之国度', loggedIn: false);
      await tester.pumpWidget(
        harness(snapshotOf(<ContentSource>[lk]), const RemoteShelfPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('还没有登录轻之国度'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
      expect(lk.shelfCalls, 0);
    });

    testWidgets('多来源：切换条可切到另一个站点', (tester) async {
      final lk = FakeShelfSource(
        id: 'lk',
        name: '轻之国度',
        books: <MediaItem>[book('lk', '轻之国度收藏')],
      );
      final lns = FakeShelfSource(
        id: 'lns',
        name: '轻书架',
        books: <MediaItem>[book('lns', '轻书架收藏')],
      );
      await tester.pumpWidget(
        harness(snapshotOf(<ContentSource>[lk, lns]), const RemoteShelfPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('轻之国度收藏'), findsOneWidget);
      expect(find.text('轻书架'), findsOneWidget);

      await tester.tap(find.text('轻书架'));
      await tester.pumpAndSettle();

      expect(find.text('轻书架收藏'), findsOneWidget);
      expect(find.text('轻之国度收藏'), findsNothing);
      expect(lns.shelfCalls, 1);
    });
  });

  group('轻书架账号页', () {
    testWidgets('已登录：渲染资料与签到，领取后按钮转已签到', (tester) async {
      var signed = false;
      final hub = StubHub((target, params) async {
        switch (target) {
          case 'GetMyInfo':
            return envelope(<Object?, Object?>{
              'Id': 9527,
              'UserName': '夹具书架友',
              'Growth': <Object?, Object?>{
                'Coin': 128,
                'SignStreak': 3,
                'TodaySigned': signed,
              },
            });
          case 'SignIn':
            signed = true;
            return envelope(<Object?, Object?>{'Reward': 20, 'Streak': 4});
        }
        throw StateError('未登记的 Hub 调用：$target');
      });
      final source = lnsSource(hub: hub);

      await tester.pumpWidget(
        harness(snapshotOf(<ContentSource>[source]), const LnsAccountPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('轻书架'), findsOneWidget);
      expect(find.text('夹具书架友'), findsOneWidget);
      expect(find.text('UID 9527'), findsOneWidget);
      expect(find.text('128'), findsOneWidget);
      expect(find.text('3 天'), findsOneWidget);
      expect(find.text('领取今日签到'), findsOneWidget);

      await tester.tap(find.text('领取今日签到'));
      await tester.pumpAndSettle();

      expect(find.text('今日已签到'), findsOneWidget);
      expect(find.textContaining('签到成功'), findsOneWidget);
    });

    testWidgets('未登录：给出「去登录」引导', (tester) async {
      final hub = StubHub((target, params) async {
        throw StateError('未登录时不应发起 Hub 调用：$target');
      });
      await tester.pumpWidget(
        harness(
          snapshotOf(<ContentSource>[lnsSource(hub: hub, loggedIn: false)]),
          const LnsAccountPage(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('还没有登录轻书架'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
    });
  });

  group('轻书架默认启用', () {
    test('联调通过后不再默认停用，且内置适配器已注册', () {
      final db = openTestDatabase();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
        ],
      );
      addTearDown(container.dispose);

      final registry = container.read(sourceRegistryProvider);

      expect(registry.defaultDisabledBuiltins, isEmpty);
      expect(registry.builtinAdapters, contains(LnsSource.id));
    });
  });
}
