import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_service.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// D40：下载调度器（`_pump`）在注入 resolver 下的停泵/恢复语义。
///
/// 覆盖 1 条与多条 pending 的组合；不读取真实网卡（resolver 全部注入替身）。
///
/// 重要实现事实：`NativeDatabase` 的查询经由**纯微任务**完成——若调度器
/// 在「排队 → WiFi 拒绝」上自旋，微任务会饿死事件循环（定时器全部停摆）。
/// 因此「单任务停泵」用例的 resolver 带**熔断器**：调用次数超阈值时把网络
/// 切回 WiFi，让自旋的泵自行排空，测试才能终止并用调用数断言自旋是否存在
/// （见该用例的注释）。多任务用例按停泵语义正常走窗口等待。
void main() {
  late AppDatabase db;
  late Preferences preferences;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    preferences = memoryPreferences();
  });

  tearDown(() => db.close);

  const item = MediaItem(
    sourceId: 'd40-source',
    remoteId: '1',
    type: MediaType.novel,
    title: '调度书',
  );

  List<Chapter> chaptersOf(int count) => <Chapter>[
    for (var index = 1; index <= count; index++)
      Chapter(
        sourceId: 'd40-source',
        remoteId: '1:$index',
        title: '第 $index 章',
      ),
  ];

  /// 可控 resolver：返回当前 WiFi 状态并计数。
  ({
    InterfaceNamesResolver resolver,
    void Function() goOnline,
    int Function() calls,
  })
  makeResolver({required bool initialWifi, int? flipToWifiAfterCalls}) {
    var wifi = initialWifi;
    var calls = 0;
    return (
      resolver: () async {
        calls += 1;
        if (flipToWifiAfterCalls != null && calls >= flipToWifiAfterCalls) {
          wifi = true;
        }
        return <String>[if (wifi) 'wlan0' else 'rmnet0'];
      },
      goOnline: () => wifi = true,
      calls: () => calls,
    );
  }

  Future<ProviderContainer> harness({
    required InterfaceNamesResolver resolver,
  }) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(preferences),
        sourceHttpClientProvider.overrideWithValue(
          FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 200, body: ''),
          ),
        ),
        sourcesProvider.overrideWith(_StubSources.new),
        downloadServiceProvider.overrideWith(
          (ref) => DownloadService(
            repository: ref.watch(downloadRepositoryProvider),
            http: ref.watch(sourceHttpClientProvider),
            preferences: ref.watch(preferencesProvider),
            interfaceNamesResolver: resolver,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<int> countOf(String status) async {
    final rows = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM downloads WHERE status = $status',
        )
        .get();
    return rows.first.data['n'] as int;
  }

  /// 给泵一个真实时间窗口（泵循环由 unawaited 触发，靠真实事件循环推进）。
  Future<void> pumpWindow(Duration duration) => Future<void>.delayed(duration);

  /// 轮询直到条件满足或超时（真实时间）。
  Future<bool> waitFor(
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await condition()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return condition();
  }

  /// D53：等待 resolver 调用数在一个窗口内不再增长（泵停住的确定性信号）。
  ///
  /// 正确实现的调用数在停泵后立刻封顶（个位数）；自旋实现每个窗口都在
  /// 增长，直到熔断器翻网、队列排空后才会稳定——两种终局都在 [maxMs]
  /// 内返回，测试永不挂死，随后由断言区分两种实现。
  Future<int> awaitCallsStable(
    int Function() calls, {
    Duration window = const Duration(milliseconds: 120),
    int maxMs = 1500,
  }) async {
    var last = calls();
    final deadline = DateTime.now().add(Duration(milliseconds: maxMs));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(window);
      final current = calls();
      if (current == last) return current;
      last = current;
    }
    return last;
  }

  test('多条 pending + wifiOnly + 非 WiFi：首任务停排队、泵停住、其余保持排队', () async {
    final net = makeResolver(initialWifi: false);
    unawaited(preferences.set(DownloadService.wifiOnlyKey, true));
    final container = await harness(resolver: net.resolver);

    final added = await container
        .read(downloadsProvider.notifier)
        .enqueue(item: item, chapters: chaptersOf(3));
    expect(added, 3);

    // 泵停住的确定性信号：调用数在窗口内不再增长（D53，替代固定等待）。
    final callsAtStop = await awaitCallsStable(net.calls);

    expect(callsAtStop, greaterThan(0), reason: 'WiFi 判定发生过');
    expect(await countOf("'queued'"), 3, reason: '非 WiFi 下没有任务被执行');
    expect(net.calls(), callsAtStop, reason: '泵停住后不再有网络判定（停泵语义）');
  });

  test('1 条 pending + wifiOnly + 非 WiFi：泵必须停住而不是自旋（缺陷回归）', () async {
    // 熔断器保留（D53 要求）：第 25 次调用起把网络切回 WiFi。正确实现
    // 的调用数只可能是个位数（run 门卫 + 泵停泵判定各一次）；若实现
    // 回退成自旋，调用数冲破熔断阈值 → 队列排空 → awaitCallsStable 在
    // 1.5 秒内返回，下面的断言立即失败——测试既可终止又能区分两种实现。
    const breaker = 25;
    final net = makeResolver(initialWifi: false, flipToWifiAfterCalls: breaker);
    unawaited(preferences.set(DownloadService.wifiOnlyKey, true));
    final container = await harness(resolver: net.resolver);

    await container
        .read(downloadsProvider.notifier)
        .enqueue(item: item, chapters: chaptersOf(1));

    // 停泵信号（调用数封顶）代替固定 5 秒轮询等待（D53）。
    final callsAtRest = await awaitCallsStable(net.calls);

    // 回归断言：单任务被 WiFi 拒绝后，泵应当停住（调用数远小于熔断阈值），
    // 任务保持 queued。
    expect(
      callsAtRest,
      lessThan(breaker),
      reason:
          '单任务被 WiFi 拒绝后泵应当停住；'
          '调用数达到熔断阈值即证明调度器在纯微任务层无限自旋，'
          '且自旋会饿死事件循环的全部定时器',
    );
    expect(await countOf("'queued'"), 1, reason: '任务保持排队等待切网');
    expect(await countOf("'done'"), 0);
  });

  test('多条 pending + wifiOnly + WiFi：全部执行到 done', () async {
    final net = makeResolver(initialWifi: true);
    unawaited(preferences.set(DownloadService.wifiOnlyKey, true));
    final container = await harness(resolver: net.resolver);

    await container
        .read(downloadsProvider.notifier)
        .enqueue(item: item, chapters: chaptersOf(3));

    final drained = await waitFor(() async => (await countOf("'done'")) == 3);
    expect(drained, isTrue);
    expect(await countOf("'queued'"), 0);
  });

  test('1 条 pending + wifiOnly + WiFi：执行到 done，泵自然结束', () async {
    final net = makeResolver(initialWifi: true);
    unawaited(preferences.set(DownloadService.wifiOnlyKey, true));
    final container = await harness(resolver: net.resolver);

    await container
        .read(downloadsProvider.notifier)
        .enqueue(item: item, chapters: chaptersOf(1));

    final drained = await waitFor(() async => (await countOf("'done'")) == 1);
    expect(drained, isTrue);
    final callsAtEnd = net.calls();
    await pumpWindow(const Duration(milliseconds: 200));
    expect(net.calls(), callsAtEnd, reason: '队列空后泵退出，不再判定网络');
  });

  test('wifiOnly 开关关闭后：明确 resume() 恢复队列，非 WiFi 也执行', () async {
    final net = makeResolver(initialWifi: false);
    unawaited(preferences.set(DownloadService.wifiOnlyKey, true));
    final container = await harness(resolver: net.resolver);

    await container
        .read(downloadsProvider.notifier)
        .enqueue(item: item, chapters: chaptersOf(2));
    final callsAtRest = await awaitCallsStable(net.calls);
    expect(await countOf("'done'"), 0, reason: '非 WiFi：泵停住');

    // 用户关闭「仅 WiFi」开关（不再改网络），随后显式 resume 恢复队列。
    await container.read(downloadServiceProvider).setWifiOnly(false);
    await container.read(downloadsProvider.notifier).resume();

    final drained = await waitFor(() async => (await countOf("'done'")) == 2);
    expect(drained, isTrue, reason: '关闭开关 + resume 后任务照常执行');
    expect(await countOf("'queued'"), 0);
    // wifiOnly=false 时 run 短路，不再做网络判定。
    expect(net.calls(), callsAtRest, reason: '关闭开关后不再消耗网络判定');
  });

  test('停泵后切回 WiFi：resume() 恢复执行剩余任务', () async {
    final net = makeResolver(initialWifi: false);
    unawaited(preferences.set(DownloadService.wifiOnlyKey, true));
    final container = await harness(resolver: net.resolver);

    await container
        .read(downloadsProvider.notifier)
        .enqueue(item: item, chapters: chaptersOf(2));
    await pumpWindow(const Duration(milliseconds: 300));
    expect(await countOf("'done'"), 0, reason: '非 WiFi：泵停住，无任务完成');

    net.goOnline();
    await container.read(downloadsProvider.notifier).resume();
    final drained = await waitFor(() async => (await countOf("'done'")) == 2);
    expect(drained, isTrue, reason: '恢复后剩余任务全部完成');
    expect(await countOf("'queued'"), 0);
  });
}

class _StubSources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: <SourceEntry>[
      SourceEntry(
        descriptor: const SourceDescriptor(
          id: 'd40-source',
          name: 'D40 夹具源',
          type: MediaType.novel,
          kind: SourceKind.builtin,
        ),
        source: _StubNovelSource(),
        enabled: true,
      ),
    ],
    failures: const <SourceFailure>[],
  );
}

class _StubNovelSource implements ContentProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'd40-source',
    name: 'D40 夹具源',
    type: MediaType.novel,
    kind: SourceKind.builtin,
  );

  @override
  bool get isReady => true;

  @override
  Future<ChapterContent> content(Chapter chapter) async =>
      const ChapterContent(text: '正文');
}
