import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_service.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// D30：WiFi 检测可注入 seam（InterfaceNamesResolver）。
///
/// `DownloadService` 的网络判定已抽成可注入解析器；本文件用替身确定性地
/// 覆盖 WiFi / 非 WiFi / 异常 / 开关四条路径，替代旧的「无法注入」限制记录
/// （原注释见 download_boundary_test.dart 的 `仅 WiFi` 组）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DownloadRepository repository;
  late Preferences preferences;

  setUp(() {
    db = openTestDatabase();
    repository = DownloadRepository(db);
    preferences = memoryPreferences();
  });

  tearDown(() => db.close());

  StubContentProvider providerOf(ChapterContent content) =>
      StubContentProvider(content);

  Future<DownloadRow> enqueueRow() async {
    final id = await repository.enqueue(
      sourceId: 'lk',
      remoteId: '1',
      chapter: const Chapter(sourceId: 'lk', remoteId: '1:1', title: '第 1 章'),
    );
    final query = db.select(db.downloads)..where((table) => table.id.equals(id));
    return query.getSingle();
  }

  DownloadService serviceOf({
    required Preferences prefs,
    InterfaceNamesResolver? resolver,
  }) => DownloadService(
    repository: repository,
    http: FakeHttpClient(
      (_) async => const SourceResponse(statusCode: 200, body: ''),
    ),
    preferences: prefs,
    interfaceNamesResolver: resolver,
  );

  group('looksLikeWifi：接口名 → WiFi 判定', () {
    test('wlan*/wifi*/en* 判为 WiFi（Android/iOS 惯例）', () {
      expect(DownloadService.looksLikeWifi(<String>['wlan0']), isTrue);
      expect(DownloadService.looksLikeWifi(<String>['wlan1']), isTrue);
      expect(DownloadService.looksLikeWifi(<String>['wifi0']), isTrue);
      expect(DownloadService.looksLikeWifi(<String>['en0']), isTrue);
    });

    test('rmnet*/eth0/lo 判为非 WiFi；空列表判为非 WiFi', () {
      expect(DownloadService.looksLikeWifi(<String>['rmnet0']), isFalse);
      expect(DownloadService.looksLikeWifi(<String>['rmnet_data0']), isFalse);
      expect(DownloadService.looksLikeWifi(<String>['eth0']), isFalse);
      expect(DownloadService.looksLikeWifi(<String>['lo']), isFalse);
      expect(DownloadService.looksLikeWifi(<String>[]), isFalse);
    });

    test('混合接口：只要有任一 WiFi 接口即判为 WiFi', () {
      expect(
        DownloadService.looksLikeWifi(<String>['rmnet0', 'wlan0']),
        isTrue,
      );
    });
  });

  group('isOnWifiDefault：解析器异常时按可用处理', () {
    test('解析成功：按接口名判定', () async {
      expect(
        await DownloadService.isOnWifiDefault(resolver: () async => <String>['wlan0']),
        isTrue,
      );
      expect(
        await DownloadService.isOnWifiDefault(resolver: () async => <String>['rmnet0']),
        isFalse,
      );
    });

    test('解析器抛错：不阻塞用户（fail-open 为 true）', () async {
      expect(
        await DownloadService.isOnWifiDefault(
          resolver: () async => throw StateError('接口枚举不可用'),
        ),
        isTrue,
      );
    });
  });

  group('run() 的 WiFi 门卫（注入替身）', () {
    test('wifiOnly + 非 WiFi：任务保持排队、不标失败、正文不取', () async {
      await preferences.set(DownloadService.wifiOnlyKey, true);
      final row = await enqueueRow();
      var contentAsked = false;

      await expectLater(
        serviceOf(
          prefs: preferences,
          resolver: () async => <String>['rmnet0'],
        ).run(
          row: row,
          provider: StubContentProvider(
            const ChapterContent(text: '不该被取到的正文'),
          )..onContent = () => contentAsked = true,
        ),
        throwsA(isA<Object>()),
      );

      final query = db.select(db.downloads)
        ..where((table) => table.id.equals(row.id));
      final after = await query.getSingle();
      expect(after.status, DownloadStatus.queued.value,
          reason: '非 WiFi 只回排队，等切网后重新调度');
      expect(after.errorMessage, isNull, reason: '排队不是失败，不写错误原因');
      expect(contentAsked, isFalse, reason: '门卫在取正文之前拦截');
    });

    test('wifiOnly + WiFi：照常执行到 done', () async {
      await preferences.set(DownloadService.wifiOnlyKey, true);
      final row = await enqueueRow();
      await serviceOf(
        prefs: preferences,
        resolver: () async => <String>['rmnet0', 'wlan0'],
      ).run(row: row, provider: providerOf(const ChapterContent(text: '正文')));

      final query = db.select(db.downloads)
        ..where((table) => table.id.equals(row.id));
      expect((await query.getSingle()).status, DownloadStatus.done.value);
    });

    test('wifiOnly + 解析器抛错：按可用处理，任务执行', () async {
      await preferences.set(DownloadService.wifiOnlyKey, true);
      final row = await enqueueRow();
      await serviceOf(
        prefs: preferences,
        resolver: () async => throw StateError('接口枚举不可用'),
      ).run(row: row, provider: providerOf(const ChapterContent(text: '正文')));

      final query = db.select(db.downloads)
        ..where((table) => table.id.equals(row.id));
      expect((await query.getSingle()).status, DownloadStatus.done.value);
    });

    test('wifiOnly 关闭：短路网络判断，解析器一次都不被调用', () async {
      final row = await enqueueRow();
      var resolverCalls = 0;
      await serviceOf(
        prefs: preferences,
        resolver: () async {
          resolverCalls += 1;
          return <String>['rmnet0'];
        },
      ).run(row: row, provider: providerOf(const ChapterContent(text: '正文')));

      expect(resolverCalls, 0, reason: '关闭开关时连网络判断都不做');
      final query = db.select(db.downloads)
        ..where((table) => table.id.equals(row.id));
      expect((await query.getSingle()).status, DownloadStatus.done.value);
    });

    test('isOnWifi() 走注入解析器而非 dart:io', () async {
      final service = serviceOf(
        prefs: preferences,
        resolver: () async => <String>['wlan0'],
      );
      expect(await service.isOnWifi(), isTrue);
    });
  });
}

/// 可编程正文来源（与 download_boundary_test 的替身同款，另带调用探针）。
class StubContentProvider implements ContentProvider {
  StubContentProvider(this.result);

  final ChapterContent result;

  /// 观察探针：正文是否被取过（WiFi 门卫测试用）。
  void Function()? onContent;

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'stub-d30',
    name: 'D30 夹具源',
    type: MediaType.novel,
    kind: SourceKind.builtin,
  );

  @override
  bool get isReady => true;

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    onContent?.call();
    return result;
  }
}
