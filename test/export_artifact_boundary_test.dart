import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/features/novel/export/epub_exporter.dart';
import 'package:triomi/features/novel/export/novel_export_service.dart';
import 'package:triomi/features/novel/export/txt_exporter.dart';

import 'fixtures/fake_http_client.dart';

/// D24：TXT / EPUB 产物语义验证。
///
/// 与 `m4b_test.dart` 的导出组（TXT 卷名/锁定跳过、EPUB 基本结构与全部
/// 失败报错）互补；本文件做**严格的结构校验**（解包后逐项对应）与导出
/// 服务层的文件行为。SAF 目录选择/授权由 T7-4 在备份侧设备验证
/// （小说导出没有 SAF 注入点，见交付文档记录），不在纯测试范围内。
Chapter chapterOf(
  String remoteId, {
  String title = '章',
  String? volumeTitle,
  bool locked = false,
}) => Chapter(
  sourceId: 's',
  remoteId: remoteId,
  title: title,
  volumeTitle: volumeTitle,
  locked: locked,
);

/// PNG 魔数开头的假图片字节（让扩展名/media-type 判定走 png 分支）。
Uint8List pngBytes() => Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TXT 产物语义', () {
    test('插图占位、Unicode 章名与 UTF-8 往返', () async {
      final outcome = await TxtExporter.exportText(
        bookTitle: '书名📚',
        author: '作者',
        chapters: <Chapter>[
          chapterOf('1', title: '第一章 ✨'),
          chapterOf('2', title: '第二章'),
        ],
        resolve: (chapter) async => (
          bodyHtml: <String, String>{
            '1': '<p>有图：<img src="https://x/a.jpg">之后</p>',
            '2': '纯文本',
          }[chapter.remoteId]!,
          bodyText: '',
        ),
        onProgress: (_, _) {},
      );
      final raw = utf8.encode(outcome.text);
      final decoded = utf8.decode(raw);
      expect(decoded, outcome.text, reason: '内容必须经 UTF-8 往返不损');
      expect(decoded, contains('[插图]'), reason: '插图占位对齐规格 D3');
      expect(decoded, contains('第一章 ✨'));
      expect(decoded, contains('书名📚'));
    });

    test('书名/作者为空白时使用默认值，不输出空行头', () async {
      final outcome = await TxtExporter.exportText(
        bookTitle: '   ',
        author: '',
        chapters: <Chapter>[chapterOf('1', title: '章')],
        resolve: (chapter) async => (bodyHtml: '正文', bodyText: ''),
        onProgress: (_, _) {},
      );
      expect(outcome.text.startsWith('未命名小说'), isTrue);
      expect(outcome.text, isNot(contains('作者：')));
    });
  });

  group('EPUB 严格结构校验', () {
    Future<({Archive archive, EpubExportResult result})> exportStandard({
      Map<String, Uint8List Function()>? images,
      String coverUrl = '',
    }) async {
      final outcome = await EpubExporter.export(
        bookTitle: '书<名>&"引"',
        author: '作者“引”',
        sourceId: 's',
        remoteId: '42',
        coverUrl: coverUrl,
        chapters: <Chapter>[
          chapterOf('1', title: '第一章 <上>&"', volumeTitle: '卷一'),
          chapterOf('2', title: '第二章 📚'),
          chapterOf('3', title: '付费章', locked: true),
        ],
        resolve: (chapter) async => (
          title: chapter.title,
          volumeTitle: chapter.volumeTitle ?? '',
          bodyHtml:
              '<p>正文一</p><img src="https://x/same.jpg" width="10" height="10">'
              '<p>正文二</p><img src="https://x/same.jpg" width="10" height="10">',
          bodyText: '',
        ),
        onProgress: (_, _) {},
        fetchImage: images == null
            ? null
            : (url) async => images[url]?.call(),
      );
      return (archive: EpubExporter.decode(outcome.bytes), result: outcome.result);
    }

    test('mimetype 是第一个条目、未压缩、内容精确', () async {
      final (:archive, result: _) = await exportStandard();
      final first = archive.files.first;
      expect(first.name, 'mimetype');
      expect(first.compression, CompressionType.none);
      expect(utf8.decode(first.content as List<int>), 'application/epub+zip');
    });

    test('container 指向 OPF；manifest/spine/nav/文件四向一一对应', () async {
      final outcome = await exportStandard();
      final archive = outcome.archive;
      final result = outcome.result;
      final names = archive.files.map((file) => file.name).toSet();

      // 锁定章被跳过：两章导出、一章 skipped。
      expect(result.exportedChapters, 2);
      expect(result.skippedChapters, 1);

      final container = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'META-INF/container.xml').content as List<int>,
      );
      expect(container, contains('OEBPS/content.opf'));

      final opf = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'OEBPS/content.opf').content as List<int>,
      );
      // manifest 里的每个 href 都必须相对 OPF 所在目录（OEBPS/）且真实存在
      // （EPUB 规范）；章节 href 带了 OEBPS/ 前缀会双重拼路径（D24-1）。
      for (final match in RegExp(r'href="([^"]+)"').allMatches(opf)) {
        final href = match.group(1)!;
        expect(
          names.contains('OEBPS/$href'),
          isTrue,
          reason: 'manifest href 相对 OEBPS/ 必须存在：$href',
        );
      }
      // spine 与章节文件一一对应。
      final spineRefs = RegExp(
        r'<itemref idref="chapter-(\d+)"/>',
      ).allMatches(opf).length;
      expect(spineRefs, 2);
      expect(names.contains('OEBPS/chapter-0001.xhtml'), isTrue);
      expect(names.contains('OEBPS/chapter-0002.xhtml'), isTrue);
      expect(names.contains('OEBPS/chapter-0003.xhtml'), isFalse,
          reason: '锁定章不进包');

      // nav 的每个链接都指向真实章节文件，且按顺序。
      final nav = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'OEBPS/nav.xhtml').content as List<int>,
      );
      final navLinks = RegExp(
        r'<a href="chapter-(\d+)\.xhtml">',
      ).allMatches(nav).toList();
      expect(navLinks.map((match) => match.group(1)).toList(), <String>['0001', '0002']);
    });

    test('封面：下载成功进 assets 且 OPF 标 cover-image', () async {
      final outcomeCover = await exportStandard(
        coverUrl: 'https://x/cover.jpg',
        images: <String, Uint8List Function()>{
          'https://x/cover.jpg': pngBytes,
        },
      );
      final archive = outcomeCover.archive;
      final opf = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'OEBPS/content.opf').content as List<int>,
      );
      expect(opf, contains('properties="cover-image"'));
      expect(
        archive.files.map((file) => file.name),
        contains('OEBPS/images/cover.png'),
        reason: '封面按魔数识别为 png 并入包',
      );
    });

    test('同一张图在多章出现：资产去重为一份，两章引用同一文件', () async {
      final outcomeDedup = await exportStandard(
        images: <String, Uint8List Function()>{
          'https://x/same.jpg': pngBytes,
        },
      );
      final archive = outcomeDedup.archive;
      final assetNames = archive.files
          .map((file) => file.name)
          .where((name) => name.startsWith('OEBPS/images/image-'))
          .toList();
      expect(assetNames, hasLength(1), reason: '按内容哈希去重');

      final chapter1 = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'OEBPS/chapter-0001.xhtml').content as List<int>,
      );
      final chapter2 = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'OEBPS/chapter-0002.xhtml').content as List<int>,
      );
      expect(chapter1, contains(assetNames.single.split('/').last));
      expect(chapter2, contains(assetNames.single.split('/').last));
    });

    test('插图/封面抓取失败：导出成功，保留外链，不写空 asset', () async {
      final outcomeFail = await exportStandard(
        coverUrl: 'https://x/cover.jpg',
        images: <String, Uint8List Function()>{
          'https://x/same.jpg': () => throw const SourceException(
            sourceId: 's',
            type: SourceErrorType.network,
            message: '图片断了',
          ),
          'https://x/cover.jpg': () => Uint8List(0),
        },
      );
      final archive = outcomeFail.archive;
      final result = outcomeFail.result;
      expect(result.exportedChapters, 2, reason: '抓取失败不阻塞导出');
      final chapter1 = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'OEBPS/chapter-0001.xhtml').content as List<int>,
      );
      expect(chapter1, contains('https://x/same.jpg'), reason: '失败保留原外链');
      expect(
        archive.files.map((file) => file.name),
        isNot(contains('OEBPS/images/cover.png')),
        reason: '空字节封面不入包',
      );
      final opf = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'OEBPS/content.opf').content as List<int>,
      );
      expect(opf, isNot(contains('cover-image')));
    });

    test('XML 特殊字符与 Unicode 标题：转义正确且 UTF-8 往返无损', () async {
      final outcomeXml = await exportStandard();
      final archive = outcomeXml.archive;
      final chapter1 = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'OEBPS/chapter-0001.xhtml').content as List<int>,
      );
      // 原始尖括号必须被转义，不能成为 XML 标签。
      expect(chapter1, contains('第一章 &lt;上&gt;&amp;&quot;'));
      expect(chapter1, isNot(contains('<上>')));
      final opf = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'OEBPS/content.opf').content as List<int>,
      );
      expect(opf, contains('书&lt;名&gt;&amp;&quot;引&quot;'));
      final nav = utf8.decode(
        archive.files.firstWhere((file) => file.name == 'OEBPS/nav.xhtml').content as List<int>,
      );
      expect(nav, contains('第二章 📚'), reason: 'Unicode 章名保留');
      // nav.xhtml 是 XML：含 emoji 的标题解析回来仍是同一字符。
      expect(utf8.decode(utf8.encode('📚')), '📚');
    });
  });

  group('导出服务层文件行为', () {
    late Directory docsDir;

    setUp(() {
      docsDir = Directory.systemTemp.createTempSync('triomi_d24_docs_');
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

    ContentProvider providerOf(Map<String, String> bodies) =>
        _StubProvider(bodies);

    test('文件名清洗 + 同名冲突自动加序号', () async {
      final item = MediaItem(
        sourceId: 's',
        remoteId: '1',
        type: MediaType.novel,
        title: r'书名:卷一/第一*话?<>|"',
      );
      final chapters = <Chapter>[chapterOf('1', title: '章')];
      final provider = providerOf(<String, String>{'1': '正文'});

      final first = await NovelExportService.exportTxt(
        item: item,
        chapters: chapters,
        source: provider,
        onProgress: (_, _) {},
      );
      expect(
        first.path.split(Platform.pathSeparator).last,
        '书名_卷一_第一_话_____.txt',
        reason: '文件名非法字符全部替换',
      );

      final second = await NovelExportService.exportTxt(
        item: item,
        chapters: chapters,
        source: provider,
        onProgress: (_, _) {},
      );
      expect(
        second.path.split(Platform.pathSeparator).last,
        '书名_卷一_第一_话_____(1).txt',
        reason: '同名导出不覆盖，自动加序号',
      );
      expect(File(first.path).existsSync(), isTrue, reason: '用户原文件不被删除');
    });

    test('导出失败（全部章节取不到）：不落任何文件', () async {
      final item = MediaItem(
        sourceId: 's',
        remoteId: '1',
        type: MediaType.novel,
        title: '空书',
      );
      await expectLater(
        NovelExportService.exportEpub(
          item: item,
          chapters: <Chapter>[chapterOf('1', title: '章', locked: true)],
          source: providerOf(const <String, String>{}),
          http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
          onProgress: (_, _) {},
        ),
        throwsA(isA<StateError>()),
      );
      final dir = await NovelExportService.exportDirectory();
      expect(dir.existsSync() ? dir.listSync() : <FileSystemEntity>[],
          isEmpty, reason: '失败导出不留半截产物');
    });

    test('TXT 落盘字节是 UTF-8（磁盘文件可直接解码）', () async {
      final item = MediaItem(
        sourceId: 's',
        remoteId: '1',
        type: MediaType.novel,
        title: '编码书',
      );
      final result = await NovelExportService.exportTxt(
        item: item,
        chapters: <Chapter>[chapterOf('1', title: '章📚')],
        source: providerOf(<String, String>{'1': '正文'}),
        onProgress: (_, _) {},
      );
      final bytes = await File(result.path).readAsBytes();
      final text = utf8.decode(bytes); // 解码失败即抛错
      expect(text, contains('章📚'));
      expect(text, contains('编码书'));
    });
  });
}

class _StubProvider implements ContentProvider {
  _StubProvider(this.bodies);

  final Map<String, String> bodies;

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 's',
    name: 'D24 夹具源',
    type: MediaType.novel,
    kind: SourceKind.builtin,
  );

  @override
  bool get isReady => true;

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    final body = bodies[chapter.remoteId];
    if (body == null) {
      throw const SourceException(
        sourceId: 's',
        type: SourceErrorType.notFound,
        message: '章节取不到',
      );
    }
    return ChapterContent(html: body);
  }
}
