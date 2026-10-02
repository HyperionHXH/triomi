import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/features/novel/lk/lk_works.dart';
import 'package:triomi/features/novel/lk/lk_works_page.dart';

/// D27：发布管理页的列表/分页/错误/空态（adapter seam 注入替身）。
void main() {
  FakeLkWorksRepository repoOf({
    Map<int, LkWorksPageResult> pages = const <int, LkWorksPageResult>{},
    Object? Function(int page)? throwFor,
  }) => FakeLkWorksRepository(pages: pages, throwFor: throwFor);

  /// 列表页有常驻的加载圈（无限动画），pumpAndSettle 会超时；
  /// 用有界 pump 让微任务与动画帧推进到位。
  Future<void> settle(WidgetTester tester, {int frames = 12}) async {
    for (var index = 0; index < frames; index++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpPage(
    WidgetTester tester,
    LkWorksRepository repository,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [lkWorksRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: LkWorksPage()),
      ),
    );
    await settle(tester);
  }

  testWidgets('列表渲染作品与元信息', (tester) async {
    await pumpPage(
      tester,
      repoOf(
        pages: <int, LkWorksPageResult>{
          1: const LkWorksPageResult(
            items: <LkWork>[
              LkWork(
                id: '1',
                title: '我的作品甲',
                updatedAt: '2026-09-30',
                chapterCount: 12,
              ),
              LkWork(id: '2', title: '我的作品乙'),
            ],
            hasMore: false,
          ),
        },
      ),
    );

    expect(find.text('我的作品甲'), findsOneWidget);
    expect(find.text('我的作品乙'), findsOneWidget);
    expect(find.text('最近更新：2026-09-30'), findsOneWidget);
    expect(find.text('最近更新未知'), findsOneWidget);
    expect(find.text('12 章'), findsOneWidget);
  });

  testWidgets('触底分页：加载下一页追加，hasMore=false 后停止', (tester) async {
    final repo = repoOf(
      pages: <int, LkWorksPageResult>{
        1: const LkWorksPageResult(
          items: <LkWork>[
            LkWork(id: '1', title: '样区作品甲'),
            LkWork(id: '1b', title: '样区作品二'),
            LkWork(id: '1c', title: '样区作品三'),
            LkWork(id: '1d', title: '样区作品四'),
            LkWork(id: '1e', title: '样区作品五'),
          ],
          hasMore: true,
        ),
        2: const LkWorksPageResult(
          items: <LkWork>[LkWork(id: '2', title: '次区作品乙')],
          hasMore: false,
        ),
      },
    );
    await pumpPage(tester, repo);
    expect(find.text('样区作品甲'), findsOneWidget);
    expect(find.text('次区作品乙'), findsNothing);

    // 触底：滚动到底触发加载第 2 页。
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await settle(tester);

    expect(find.text('次区作品乙'), findsOneWidget);
    expect(repo.requestedPages, <int>[1, 2]);

    // 已经没有更多：继续滚动不再发请求。
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await settle(tester);
    expect(repo.requestedPages, <int>[1, 2], reason: 'hasMore=false 后停止分页');
  });

  testWidgets('错误态可重试；重试成功恢复列表', (tester) async {
    final repo = repoOf(
      throwFor: (page) => const SourceException(
        sourceId: 'light-novel-kingdom',
        type: SourceErrorType.network,
        message: 'HTTP 500',
      ),
      pages: <int, LkWorksPageResult>{
        1: const LkWorksPageResult(
          items: <LkWork>[LkWork(id: '1', title: '重试后出现')],
          hasMore: false,
        ),
      },
    );
    await pumpPage(tester, repo);

    expect(find.textContaining('HTTP 500'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    repo.throwFor = null;
    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(find.text('重试后出现'), findsOneWidget);
  });

  testWidgets('空列表给空态提示而不是空白', (tester) async {
    await pumpPage(
      tester,
      repoOf(
        pages: <int, LkWorksPageResult>{
          1: const LkWorksPageResult(items: <LkWork>[], hasMore: false),
        },
      ),
    );
    expect(find.text('还没有发布作品'), findsOneWidget);
  });

  testWidgets('默认 seam（接口未接入）：可读错误而不是崩溃或假空列表', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LkWorksPage())),
    );
    await settle(tester);
    expect(find.textContaining('尚未接入'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  test('默认 seam 抛出来源解析错误（不是崩溃）', () async {
    await expectLater(
      const LkWorksUnavailable().fetchPage(1),
      throwsA(
        isA<SourceException>().having(
          (error) => error.type,
          'type',
          SourceErrorType.parse,
        ),
      ),
    );
  });
}

/// 记录请求页码的替身：按页回放预设结果或异常。
class FakeLkWorksRepository implements LkWorksRepository {
  FakeLkWorksRepository({
    this.pages = const <int, LkWorksPageResult>{},
    this.throwFor,
  });

  final Map<int, LkWorksPageResult> pages;
  Object? Function(int page)? throwFor;
  final List<int> requestedPages = <int>[];

  @override
  Future<LkWorksPageResult> fetchPage(int page) async {
    requestedPages.add(page);
    final thrown = throwFor?.call(page);
    if (thrown != null) throw thrown;
    final result = pages[page];
    if (result == null) {
      throw StateError('夹具没有准备第 $page 页');
    }
    return result;
  }
}
