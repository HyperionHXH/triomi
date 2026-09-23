import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/text/zh_converter.dart';
import 'package:triomi/features/novel/export/epub_exporter.dart';
import 'package:triomi/features/novel/export/txt_exporter.dart';

ArchiveFile _entry(Archive archive, String name) =>
    archive.files.firstWhere((file) => file.name == name);

void main() {
  group('ZhConverter', () {
    test('单字映射：简→繁与繁→简，方向关闭时原样返回', () {
      final converter = ZhConverter.fromMaps(
        s2t: {'后': '後', '发': '發'},
        t2s: {'後': '后', '發': '发'},
      );
      expect(converter.convert('皇后發展', ZhConversionMode.s2t), '皇後發展');
      expect(converter.convert('皇後發展', ZhConversionMode.t2s), '皇后发展');
      expect(converter.convert('皇后', ZhConversionMode.off), '皇后');
      expect(converter.convert('', ZhConversionMode.s2t), '');
    });

    test('字典里没有的字保持不变', () {
      final converter = ZhConverter.fromMaps(s2t: {'简': '簡'}, t2s: {});
      expect(converter.convert('abc 简 ☕', ZhConversionMode.s2t), 'abc 簡 ☕');
    });

    test('OpenCC 字表格式解析：取第一个候选，忽略注释', () {
      final map = parseDictText('# comment\n幹\t幹 干\n后\t後 後\n');
      expect(map['幹'], '幹');
      expect(map['后'], '後');
      expect(map.length, 2);
    });
  });

  group('TxtExporter', () {
    Future<({String text, TxtExportResult result})> runExport({
      required List<Chapter> chapters,
      required Map<String, String> bodies,
    }) {
      return TxtExporter.exportText(
        bookTitle: '测试之书',
        author: '测试者',
        chapters: chapters,
        resolve: (chapter) async {
          final body = bodies[chapter.remoteId];
          if (body == null) return null;
          return (bodyHtml: body, bodyText: '');
        },
        onProgress: (_, _) {},
      );
    }

    test('HTML 正文转纯文本，卷名/章名/书名/作者齐全', () async {
      final outcome = await runExport(
        chapters: [
          Chapter(
            sourceId: 's',
            remoteId: '1',
            title: '第一章',
            volumeTitle: '第一卷',
          ),
          Chapter(sourceId: 's', remoteId: '2', title: '第二章'),
        ],
        bodies: {'1': '<p>第一段。</p><p>第二段。</p>', '2': '纯文本正文'},
      );
      expect(outcome.result.exportedChapters, 2);
      expect(outcome.result.skippedChapters, 0);
      expect(outcome.text, contains('测试之书'));
      expect(outcome.text, contains('作者：测试者'));
      expect(outcome.text, contains('【第一卷】'));
      expect(outcome.text, contains('【正文】'));
      expect(outcome.text, contains('第一段。\n\n第二段。'));
      expect(outcome.text, contains('纯文本正文'));
    });

    test('锁定章节跳过且计入 skipped，取数失败也不阻塞', () async {
      final outcome = await runExport(
        chapters: [
          Chapter(sourceId: 's', remoteId: '1', title: '免费章'),
          Chapter(sourceId: 's', remoteId: '2', title: '付费章', locked: true),
          Chapter(sourceId: 's', remoteId: '3', title: '取不回来的章'),
        ],
        bodies: {'1': '<p>正文</p>'},
      );
      expect(outcome.result.exportedChapters, 1);
      expect(outcome.result.skippedChapters, 2);
      expect(outcome.text, isNot(contains('付费章')));
    });

    test('全部锁定时抛出可读错误', () async {
      await expectLater(
        runExport(
          chapters: [
            Chapter(sourceId: 's', remoteId: '1', title: '付费章', locked: true),
          ],
          bodies: const <String, String>{},
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('EpubExporter', () {
    test('打包结构：mimetype 未压缩、container/nav/opf/章节齐全、锁定章跳过', () async {
      final outcome = await EpubExporter.export(
        bookTitle: '导出之书',
        author: '作者甲',
        sourceId: 'lk',
        remoteId: '42',
        coverUrl: '',
        chapters: [
          Chapter(sourceId: 'lk', remoteId: '1', title: '第一章'),
          Chapter(sourceId: 'lk', remoteId: '2', title: '付费章', locked: true),
          Chapter(sourceId: 'lk', remoteId: '3', title: '第二章'),
        ],
        resolve: (chapter) async => (
          title: chapter.title,
          volumeTitle: '',
          bodyHtml: '<p>${chapter.title}的内容。</p>',
          bodyText: '',
        ),
        onProgress: (_, _) {},
      );
      expect(outcome.result.exportedChapters, 2);
      expect(outcome.result.skippedChapters, 1);

      final archive = EpubExporter.decode(outcome.bytes);
      final names = archive.files.map((file) => file.name).toList();
      expect(names.first, 'mimetype');
      expect(
        utf8.decode(_entry(archive, 'mimetype').content),
        'application/epub+zip',
      );
      expect(names, contains('META-INF/container.xml'));
      expect(names, contains('OEBPS/nav.xhtml'));
      expect(names, contains('OEBPS/content.opf'));
      expect(names, contains('OEBPS/chapter-0001.xhtml'));
      expect(names, contains('OEBPS/chapter-0002.xhtml'));

      final opf = utf8.decode(_entry(archive, 'OEBPS/content.opf').content);
      expect(opf, contains('urn:triomi:lk:42'));
      expect(opf, contains('<dc:title>导出之书</dc:title>'));
      expect(opf, contains('<dc:creator>作者甲</dc:creator>'));
      expect(opf, isNot(contains('付费章')));

      final chapter1 = utf8.decode(
        _entry(archive, 'OEBPS/chapter-0001.xhtml').content,
      );
      expect(chapter1, contains('<h2>第一章</h2>'));
      expect(chapter1, contains('<p>第一章的内容。</p>'));
    });

    test('正文里的插图下载后进包并重写地址；失败保留原地址', () async {
      final fetched = <String>[];
      final outcome = await EpubExporter.export(
        bookTitle: '插图之书',
        author: '',
        sourceId: 'lk',
        remoteId: '7',
        coverUrl: '',
        chapters: [Chapter(sourceId: 'lk', remoteId: '1', title: '章')],
        resolve: (chapter) async => (
          title: chapter.title,
          volumeTitle: '',
          bodyHtml:
              '<p>图前</p><img src="https://example.test/pic.png"/><p>图后</p>',
          bodyText: '',
        ),
        onProgress: (_, _) {},
        fetchImage: (url) async {
          fetched.add(url);
          return Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
        },
      );
      expect(fetched, ['https://example.test/pic.png']);
      final archive = EpubExporter.decode(outcome.bytes);
      final names = archive.files.map((file) => file.name).toList();
      expect(
        names.any(
          (name) =>
              name.startsWith('OEBPS/images/image-') && name.endsWith('.png'),
        ),
        isTrue,
      );
      final chapter = utf8.decode(
        _entry(archive, 'OEBPS/chapter-0001.xhtml').content,
      );
      expect(chapter, contains('<img src="images/image-'));
    });

    test('没有可导出的章节时抛出错误', () async {
      await expectLater(
        EpubExporter.export(
          bookTitle: '空书',
          author: '',
          sourceId: 'lk',
          remoteId: '1',
          coverUrl: '',
          chapters: [
            Chapter(sourceId: 'lk', remoteId: '1', title: '付费章', locked: true),
          ],
          resolve: (chapter) async => null,
          onProgress: (_, _) {},
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
