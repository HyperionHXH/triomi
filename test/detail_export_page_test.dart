import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:triomi/features/detail/detail_page.dart';

import 'fixtures/fake_http_client.dart';

/// D39：详情页导出流程的 SAF seam widget 测试（D29/D30 接收后的页面层回归）。
///
/// 覆盖：SAF 目录选择取消（回退私有目录）、EPUB/TXT 的 MIME 契约、
/// 授权目录写入失败回退。全部通过 `triomi/platform` 的 mock 通道驱动，
/// 不触真实 SAF / 真实文件系统（私有目录指到 tempdir）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  final recordedWrites = <({String treeUri, String fileName, String mime})>[];
  Object? writeToTreeError;
  String? pickDirectoryResult;

  Future<Object?>? platformHandler(MethodCall call) async {
    switch (call.method) {
      case 'pickDirectory':
        return pickDirectoryResult;
      case 'writeToTree':
        final args = call.arguments as Map<Object?, Object?>;
        if (writeToTreeError != null) throw writeToTreeError!;
        recordedWrites.add((
          treeUri: '${args['treeUri']}',
          fileName: '${args['fileName']}',
          mime: '${args['mime']}',
        ));
        // D49：模拟系统真实行为——createDocument 返回的 document URI
        // 可能与请求文件名不同（重名加序号）。
        return '${args['treeUri']}/document/renamed-${args['fileName']}';
    }
    return null;
  }

  setUp(() {
    docsDir = Directory.systemTemp.createTempSync('triomi_d39_docs_');
    pickDirectoryResult = null;
    writeToTreeError = null;
    recordedWrites.clear();
    const channel = MethodChannel('triomi/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, platformHandler);
    // 私有目录回退路径的 path_provider 指到 tempdir。
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return call.method == 'getApplicationDocumentsDirectory'
              ? docsDir.path
              : null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
    });
  });

  tearDown(() {
    try {
      docsDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟交给系统清理。
    }
  });

  const item = MediaItem(
    sourceId: 'd39-source',
    remoteId: '1',
    type: MediaType.novel,
    title: '导出小说',
  );

  Future<void> pumpDetail(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(
            AppDatabase.forTesting(NativeDatabase.memory()),
          ),
          sourcesProvider.overrideWith(() => StubSources(snapshotOf())),
          sourceHttpClientProvider.overrideWithValue(
            FakeHttpClient(
              (_) async => const SourceResponse(statusCode: 200, body: ''),
            ),
          ),
        ],
        child: const MaterialApp(home: DetailPage(item: item)),
      ),
    );
    // 等详情与目录加载完成。
    for (var index = 0; index < 10; index++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 打开「导出」菜单并选择 EPUB / TXT；导出对话框含无限进度圈，
  /// 只能有界 pump 推进到完成。
  Future<void> runExport(WidgetTester tester, {required bool epub}) async {
    await tester.tap(find.byTooltip('导出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(epub ? '导出 EPUB' : '导出 TXT'));
    // 授权目录路径只走 mock 通道（微任务即可完成）；回退路径有真实文件 IO，
    // 在 widget 测试的 FakeAsync 区不会被 pump 推进——用 runAsync 在真实
    // 事件循环里等导出完成，再 pump 回 UI 渲染 snackbar。
    // 微任务链（mock 通道回执）与真实文件 IO（回退写盘）交替推进：
    // pump 冲刷微任务并发起 IO，runAsync 让 OS 侧完成 IO，再 pump 送达回调。
    for (var round = 0; round < 8; round++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      for (var index = 0; index < 5; index++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }
  }

  testWidgets('SAF 目录选择取消：回退私有目录，不调用 writeToTree', (tester) async {
    pickDirectoryResult = null; // 用户取消。
    await pumpDetail(tester);
    await runExport(tester, epub: true);

    expect(recordedWrites, isEmpty, reason: '取消选择就不该写授权目录');
    expect(find.textContaining('导出完成'), findsOneWidget, reason: '回退是导出成功');
    expect(find.textContaining('未选择授权目录，已保存到应用导出目录'),
        findsOneWidget, reason: 'D50：取消目录与权限失败分开提示');
    expect(
      find.textContaining(docsDir.path),
      findsOneWidget,
      reason: 'snackbar 显示私有目录回退路径',
    );
    final exports = Directory(
      '${docsDir.path}${Platform.pathSeparator}exports',
    );
    expect(exports.existsSync(), isTrue);
    expect(
      exports.listSync().map((entity) => entity.path.endsWith('.epub')),
      isNotEmpty,
    );
  });

  testWidgets('EPUB 导出：writeToTree 收到 application/epub+zip', (tester) async {
    pickDirectoryResult = 'content://tree/exports';
    await pumpDetail(tester);
    await runExport(tester, epub: true);

    expect(recordedWrites, hasLength(1));
    expect(recordedWrites.single.mime, 'application/epub+zip');
    expect(recordedWrites.single.fileName, '导出小说.epub');
    expect(recordedWrites.single.treeUri, 'content://tree/exports');
    expect(
      find.textContaining(
        'content://tree/exports/document/renamed-导出小说.epub',
      ),
      findsOneWidget,
      reason: 'snackbar 显示系统返回的真实 document URI（D49）',
    );
    expect(find.textContaining('已保存到授权目录'), findsOneWidget,
        reason: 'D50：显式区分保存位置');
  });

  testWidgets('TXT 导出：writeToTree 收到 text/plain', (tester) async {
    pickDirectoryResult = 'content://tree/exports';
    await pumpDetail(tester);
    await runExport(tester, epub: false);

    expect(recordedWrites, hasLength(1));
    expect(recordedWrites.single.mime, 'text/plain');
    expect(recordedWrites.single.fileName, '导出小说.txt');
  });

  testWidgets('授权目录写入失败：回退私有目录并在 snackbar 提示回退路径', (tester) async {
    pickDirectoryResult = 'content://broken/tree';
    writeToTreeError = PlatformException(
      code: 'create_failed',
      message: '权限被回收',
    );
    await pumpDetail(tester);
    await runExport(tester, epub: false);

    expect(find.textContaining('导出完成'), findsOneWidget, reason: '回退成功不报失败');
    expect(find.textContaining('授权目录写入失败，已保存到应用导出目录'),
        findsOneWidget, reason: 'D50：失败回退与取消选择分开提示');
    expect(
      find.textContaining(docsDir.path),
      findsOneWidget,
      reason: '提示里给出私有目录回退路径（写入失败回退提示）',
    );
    expect(
      find.textContaining('content://broken/tree'),
      findsNothing,
      reason: '不再显示写失败的授权路径',
    );
  });
}

class StubSources extends SourceRegistryController {
  StubSources(this.snapshot);

  final SourceRegistrySnapshot snapshot;

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

SourceRegistrySnapshot snapshotOf() => SourceRegistrySnapshot(
  entries: <SourceEntry>[
    SourceEntry(
      descriptor: const SourceDescriptor(
        id: 'd39-source',
        name: 'D39 夹具源',
        type: MediaType.novel,
        kind: SourceKind.builtin,
      ),
      source: _StubNovelSource(),
      enabled: true,
    ),
  ],
  failures: const <SourceFailure>[],
);

class _StubNovelSource implements DetailProvider, ContentProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'd39-source',
    name: 'D39 夹具源',
    type: MediaType.novel,
    kind: SourceKind.builtin,
  );

  @override
  bool get isReady => true;

  @override
  Future<MediaItem> detail(MediaItem item) async => item;

  @override
  Future<List<Chapter>> chapters(MediaItem item) async => const <Chapter>[
    Chapter(sourceId: 'd39-source', remoteId: '1:1', title: '第一章'),
    Chapter(sourceId: 'd39-source', remoteId: '1:2', title: '第二章'),
  ];

  @override
  Future<ChapterContent> content(Chapter chapter) async =>
      const ChapterContent(text: '正文内容');
}
