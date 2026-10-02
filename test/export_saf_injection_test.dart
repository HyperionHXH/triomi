import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/features/novel/export/novel_export_service.dart';

import 'fixtures/fake_http_client.dart';

/// D29：小说导出的 SAF 注入（授权目录优先，私有目录回退）。
Chapter chapterOf(String remoteId) => Chapter(
  sourceId: 's',
  remoteId: remoteId,
  title: '第一章',
);

MediaItem itemOf(String title) => MediaItem(
  sourceId: 's',
  remoteId: '1',
  type: MediaType.novel,
  title: title,
);

class StubProvider implements ContentProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 's',
    name: 'D29 夹具源',
    type: MediaType.novel,
    kind: SourceKind.builtin,
  );

  @override
  bool get isReady => true;

  @override
  Future<ChapterContent> content(Chapter chapter) async =>
      const ChapterContent(text: '正文内容');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;

  setUp(() {
    docsDir = Directory.systemTemp.createTempSync('triomi_d29_docs_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return call.method == 'getApplicationDocumentsDirectory'
              ? docsDir.path
              : null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  });

  tearDown(() {
    try {
      docsDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟交给系统清理。
    }
  });

  group('SAF 导出注入', () {
    test('EPUB：path 使用返回的真实 document URI（系统改名场景）', () async {
      final writes = <({String uri, String fileName, List<int> bytes})>[];
      const documentUri =
          'content://com.android.externalstorage/document/exports/注入书 (1).epub';
      final result = await NovelExportService.exportEpub(
        item: itemOf('注入书'),
        chapters: <Chapter>[chapterOf('1')],
        source: StubProvider(),
        http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
        onProgress: (_, _) {},
        directoryUri: 'content://com.android.externalstorage/tree/exports',
        writeToTree: (uri, fileName, bytes) async {
          writes.add((uri: uri, fileName: fileName, bytes: bytes));
          return documentUri;
        },
      );

      expect(writes, hasLength(1));
      expect(writes.single.fileName, '注入书.epub');
      expect(writes.single.bytes, isNotEmpty);
      // 系统把文件改名为「注入书 (1).epub」：真实 URI 才是实际位置，
      // 合成的 treeUri/fileName 路径是错的（D49 合同）。
      expect(result.path, documentUri);
      // 私有目录不落文件。
      final dir = await NovelExportService.exportDirectory();
      expect(dir.existsSync() ? dir.listSync() : <FileSystemEntity>[], isEmpty);
    });

    test('TXT 同样支持授权目录注入并回传真实 URI', () async {
      final writes = <({String fileName, List<int> bytes})>[];
      const documentUri = 'content://authors/document/注入书.txt';
      final result = await NovelExportService.exportTxt(
        item: itemOf('注入书'),
        chapters: <Chapter>[chapterOf('1')],
        source: StubProvider(),
        onProgress: (_, _) {},
        directoryUri: 'content://authors/tree/exports',
        writeToTree: (uri, fileName, bytes) async {
          writes.add((fileName: fileName, bytes: bytes));
          return documentUri;
        },
      );

      expect(writes.single.fileName, '注入书.txt');
      expect(utf8.decode(writes.single.bytes), contains('注入书'));
      expect(result.path, documentUri);
    });

    test('注入器返回空 URI：视为失败，回退私有目录（D49）', () async {
      final result = await NovelExportService.exportTxt(
        item: itemOf('空 URI 书'),
        chapters: <Chapter>[chapterOf('1')],
        source: StubProvider(),
        onProgress: (_, _) {},
        directoryUri: 'content://empty/tree',
        writeToTree: (uri, fileName, bytes) async => '',
      );

      final file = File(result.path);
      expect(file.existsSync(), isTrue);
      expect(result.path.startsWith(docsDir.path), isTrue,
          reason: '空 URI 不构成成功路径');
    });

    test('SAF 写入失败：回退私有目录且文件可读', () async {
      final result = await NovelExportService.exportTxt(
        item: itemOf('回退书'),
        chapters: <Chapter>[chapterOf('1')],
        source: StubProvider(),
        onProgress: (_, _) {},
        directoryUri: 'content://broken/tree',
        writeToTree: (uri, fileName, bytes) async {
          throw StateError('权限被回收');
        },
      );

      final file = File(result.path);
      expect(file.existsSync(), isTrue, reason: '回退到私有目录并落盘');
      expect(result.path.startsWith(docsDir.path), isTrue,
          reason: '回退路径在应用文档目录下');
      expect(utf8.decode(file.readAsBytesSync()), contains('回退书'));
    });

    test('未提供授权目录（取消/未选择）：走私有目录', () async {
      var called = false;
      final result = await NovelExportService.exportTxt(
        item: itemOf('私有书'),
        chapters: <Chapter>[chapterOf('1')],
        source: StubProvider(),
        onProgress: (_, _) {},
        writeToTree: (uri, fileName, bytes) async {
          called = true;
          return '';
        },
      );

      expect(called, isFalse, reason: '没有 directoryUri 就不该调用注入器');
      expect(File(result.path).existsSync(), isTrue);
      expect(result.path, contains('exports'));
    });
  });
}
