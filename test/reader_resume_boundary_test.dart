import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/novel/reader/novel_blocks.dart';

/// D23：阅读解析、分页与续读边界。
///
/// 与 `reader_pagination_test.dart`（测量/渲染样式一致性）、
/// `reader_settings_test.dart`（设置持久化）、`m4b_reader_zh_test.dart`
/// （繁简转换）、`t6_reader_security_test.dart`（登出清理）互补。
/// 断言原则（工作单要求）：内容没有丢失、位置合法、没有空白死循环；
/// 不绑定某个环境下的精确分页数量。

PaginationStyle styleOf({
  double fontSize = 16,
  double width = 300,
  double height = 600,
}) => PaginationStyle(
  paragraphStyle: TextStyle(fontSize: fontSize, height: 1.5),
  headingStyle: TextStyle(fontSize: fontSize + 4, height: 1.4),
  pageWidth: width,
  pageHeight: height,
  spacing: 8,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderContentParser 边界', () {
    List<ReaderBlock> parseHtml(String html) =>
        ReaderContentParser.parse(bodyHtml: html, bodyText: '');

    test('HTML 实体解码：十进制/十六进制解码，非法实体原样保留', () {
      final blocks = parseHtml('<p>&#x4E2D;&#25991; &amp; &lt;标签&gt;</p>');
      expect((blocks.single as ParagraphBlock).text, '中文 & <标签>');

      final invalid = parseHtml('<p>&#zzz; 尾随</p>');
      expect((invalid.single as ParagraphBlock).text, '&#zzz; 尾随');
    });

    test('协议相对与 http 图片地址升级为 https', () {
      final blocks = parseHtml(
        '<p><img src="//cdn.example.com/a.jpg"></p>'
        '<p><img src="http://cdn.example.com/b.jpg"></p>',
      );
      final urls = <String>[
        for (final block in blocks)
          if (block is IllustrationBlock) block.url,
      ];
      expect(urls, <String>[
        'https://cdn.example.com/a.jpg',
        'https://cdn.example.com/b.jpg',
      ]);
    });

    test('缺尺寸 / 零 / 负尺寸插图：解析不崩溃，宽高比走兜底', () {
      final blocks = parseHtml(
        '<p><img src="https://x/1.jpg"></p>'
        '<p><img src="https://x/2.jpg" width="0" height="0"></p>'
        '<p><img src="https://x/3.jpg" width="-40" height="-20"></p>',
      );
      final illustrations = <IllustrationBlock>[
        for (final block in blocks)
          if (block is IllustrationBlock) block,
      ];
      expect(illustrations, hasLength(3));
      for (final illustration in illustrations) {
        expect(illustration.aspectRatio, greaterThan(0),
            reason: '非法尺寸回退到默认宽高比');
      }
    });

    test('标题/正文/段内插图按文档顺序混排', () {
      final blocks = parseHtml(
        '<h2>卷一</h2>'
        '<p>开头<img src="https://x/mid.jpg" width="100" height="80">结尾</p>'
        '<p class="ln-paragraph--indent">第二段</p>',
      );
      expect(blocks, hasLength(5));
      expect(blocks[0], isA<HeadingBlock>());
      expect((blocks[0] as HeadingBlock).text, '卷一');
      expect((blocks[1] as ParagraphBlock).text, '开头');
      expect(blocks[2], isA<IllustrationBlock>());
      expect((blocks[3] as ParagraphBlock).text, '结尾');
      expect((blocks[4] as ParagraphBlock).text, '第二段');
      expect((blocks[4] as ParagraphBlock).firstLineIndent, isTrue);
      // 段内插图之后的文本不再带缩进（首行缩进只作用于第一段文本）。
      expect((blocks[3] as ParagraphBlock).firstLineIndent, isFalse);
    });

    test('空正文：给「本章暂无正文」占位，不产生空页死循环', () {
      final empty = ReaderContentParser.parse(bodyHtml: '', bodyText: '');
      expect(empty, hasLength(1));
      expect((empty.single as ParagraphBlock).text, '本章暂无正文');

      final pages = paginateReaderBlocks(empty, styleOf());
      expect(pages, hasLength(1));
      expect(pages.single.elements, isNotEmpty);
    });

    test('纯文本兜底：[res] 资源标记替换为可读占位', () {
      final blocks = ReaderContentParser.parse(
        bodyHtml: '',
        bodyText: '第一段\n[res]image:abc[/res]\n第二段',
      );
      expect(blocks, hasLength(3));
      expect(
        (blocks[1] as ParagraphBlock).text,
        '【插图暂时无法加载】',
      );
    });

    test('只有插图没有文本：可解析可分页', () {
      final blocks = parseHtml(
        '<img src="https://x/1.jpg" width="800" height="600">'
        '<img src="https://x/2.jpg" width="800" height="600">',
      );
      expect(blocks.whereType<IllustrationBlock>(), hasLength(2));
      final pages = paginateReaderBlocks(blocks, styleOf(height: 400));
      expect(pages, isNotEmpty);
      for (final page in pages) {
        expect(page.elements, isNotEmpty, reason: '不允许空白页');
      }
    });
  });

  group('分页边界', () {
    test('长段落跨页切断：内容不丢、页页非空、有限终止', () {
      final source = List<String>.filled(
        60,
        '这一段非常长，用来验证跨页切断时每个字符都能回到某一页上，'
        '同时分页必须在有限步内结束，不能出现空白页或死循环。',
      ).join();
      final blocks = <ReaderBlock>[ParagraphBlock(source)];
      final pages = paginateReaderBlocks(blocks, styleOf(width: 220, height: 240));

      expect(pages.length, greaterThan(3), reason: '长段落应当确实分出多页');
      final rebuilt = StringBuffer();
      for (final page in pages) {
        expect(page.elements, isNotEmpty);
        for (final element in page.elements) {
          if (element is TextElement) rebuilt.write(element.text);
        }
      }
      // 首行缩进的「　　」是显示装饰，参与测量但不属于原文。
      expect(rebuilt.toString().replaceFirst('　　', ''), source,
          reason: '所有文本必须一字不差地保留');
    });

    test('连续换行/空段：不产生空白页，有限终止', () {
      final blocks = ReaderContentParser.parse(
        bodyHtml: '',
        bodyText: '第一段\n\n\n\n\n\n\n\n第二段\n\n\n\n第三段',
      );
      final pages = paginateReaderBlocks(blocks, styleOf());
      expect(pages, hasLength(1), reason: '空段被解析层过滤，不应撑出空白页');
      expect(
        pages.single.elements.whereType<TextElement>().length,
        3,
      );
    });

    test('字号/宽度变化后：块下标位置保持合法，可用于续读恢复', () async {
      final blocks = <ReaderBlock>[
        const HeadingBlock('第一章'),
        ParagraphBlock('正文甲。' * 40),
        ParagraphBlock('正文乙。' * 40),
        const IllustrationBlock('https://x/pic.jpg', width: 600, height: 400),
        ParagraphBlock('正文丙。' * 40),
      ];

      final positions = <int>[];
      for (final style in <PaginationStyle>[
        styleOf(fontSize: 14, width: 320, height: 640),
        styleOf(fontSize: 20, width: 300, height: 600),
        styleOf(fontSize: 16, width: 220, height: 420),
      ]) {
        final pages = paginateReaderBlocks(blocks, style);
        expect(pages, isNotEmpty);
        var lastBlockIndex = -1;
        for (final page in pages) {
          expect(page.elements, isNotEmpty);
          final firstIndex = page.elements.first.blockIndex;
          expect(firstIndex, greaterThanOrEqualTo(lastBlockIndex),
              reason: '页首块下标必须单调不减（续读位置才可回放）');
          expect(firstIndex, lessThan(blocks.length), reason: '块下标必须合法');
          lastBlockIndex = firstIndex;
        }
        positions.add(pages.first.elements.first.blockIndex);
        // 续读恢复：任意合法块下标都能在某一页上找到落点（第一元素即它）。
        for (var index = 0; index < blocks.length; index++) {
          final owner = pages.where(
            (page) => page.elements.any(
              (element) => element.blockIndex == index,
            ),
          );
          expect(owner, isNotEmpty, reason: '块 $index 必须出现在某一页上');
        }
      }
      expect(positions, everyElement(0), reason: '起点都是第一章开头');
    });

    test('带 emoji 的长段落：页面边界不得把代理对切成半截字符', () async {
      final source =
          '前面一些文字 😀😀😀 然后继续直到越过页边界 🎉🔥📚 更多文字来保证跨页。' * 8;
      final pages = paginateReaderBlocks(
        <ReaderBlock>[ParagraphBlock(source)],
        styleOf(width: 180, height: 200),
      );
      expect(pages.length, greaterThan(2));

      final rebuilt = StringBuffer();
      var firstFragment = true;
      for (final page in pages) {
        for (final element in page.elements) {
          if (element is TextElement) {
            rebuilt.write(
              firstFragment
                  ? element.text.replaceFirst('　　', '')
                  : element.text,
            );
            firstFragment = false;
            expect(
              _hasLoneSurrogate(element.text),
              isFalse,
              reason: '页面边界不能把 emoji 切成半截（渲染为乱码）：'
                  '${element.text.codeUnits.where(_isSurrogateHalf).toList()}',
            );
          }
        }
      }
      expect(rebuilt.toString(), source, reason: '内容不丢');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('续读位置隔离（保存/恢复）', () {
    late AppDatabase db;
    late LibraryRepository library;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      library = LibraryRepository(db);
    });

    tearDown(() => db.close);

    Future<void> record(
      String sourceId,
      String remoteId,
      String chapterRemoteId,
      double position,
    ) async {
      await library.recordHistory(
        sourceId: sourceId,
        remoteId: remoteId,
        chapter: Chapter(
          sourceId: sourceId,
          remoteId: chapterRemoteId,
          title: chapterRemoteId,
        ),
        position: position,
      );
    }

    test('不同来源同 ID：位置互不串', () async {
      await record('lk', '1001', '1001:1', 3);
      await record('lns', '1001', '1001:1', 9);

      final lk = await library.lastReadOf('lk', '1001');
      final lns = await library.lastReadOf('lns', '1001');
      expect(lk?.position, 3);
      expect(lns?.position, 9);
      expect(lk?.chapterRemoteId, '1001:1');
    });

    test('同书不同章：各自的位置都保留，续读取最近一次', () async {
      await record('lk', '1001', '1001:1', 3);
      await record('lk', '1001', '1001:2', 7);

      final all = await library.recentHistory(limit: 20);
      final lkRows = all
          .where((view) => view.sourceId == 'lk' && view.remoteId == '1001')
          .toList();
      expect(lkRows, hasLength(2), reason: '两章各一行，不倍增');
      expect(
        {for (final row in lkRows) row.chapterRemoteId: row.position},
        <String, double>{'1001:1': 3, '1001:2': 7},
      );

      // 回到第 1 章再读：旧行原位更新而不是倍增。
      // 历史时间按秒存，同秒内多次记录的先后无法区分——这里用一次
      // 越过秒边界的等待构造确定性的「最近一次」。
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await record('lk', '1001', '1001:1', 4);

      final latest = await library.lastReadOf('lk', '1001');
      expect(latest?.chapterRemoteId, '1001:1', reason: '最近一次读的是第 1 章');
      expect(latest?.position, 4);
      final after = await library.recentHistory(limit: 20);
      expect(
        after
            .where((view) => view.sourceId == 'lk' && view.remoteId == '1001')
            .length,
        2,
      );
    });

    test('「全部标为已读」只清本地未读提示，不触碰远端阅读历史', () async {
      // 结构性证据：LibraryRepository 不持有任何 HTTP 通道，
      // markAllRead 是纯 drift 更新（G2）；远端同步只在阅读器
      // _persistProgress(commit: true) 里发生，与标已读无调用关系。
      // （unread_count 的写入方是 G1 缺口，这里用 SQL 模拟未来的写入方。）
      await library.addToLibrary(
        const MediaItem(
          sourceId: 'lk',
          remoteId: '1001',
          type: MediaType.novel,
          title: '书',
        ),
      );
      await record('lk', '1001', '1001:1', 3);
      await db.customStatement(
        'UPDATE library_entries SET unread_count = 2',
      );
      final cleared = await library.markAllRead();
      expect(cleared, 1);
      expect(await library.lastReadOf('lk', '1001'), isNotNull,
          reason: '标已读不删除阅读历史');
      final all = await library.recentHistory(limit: 20);
      expect(all, isNotEmpty, reason: '本地提示清理不等于历史丢失');
    });
  });
}

bool _isSurrogateHalf(int unit) =>
    (unit >= 0xD800 && unit <= 0xDBFF) || (unit >= 0xDC00 && unit <= 0xDFFF);

bool _hasLoneSurrogate(String text) {
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      // 高代理后面必须紧跟低代理，否则是半截字符。
      final next = index + 1 < text.length ? text.codeUnitAt(index + 1) : 0;
      if (next < 0xDC00 || next > 0xDFFF) return true;
      index++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      // 低代理不能作为开头出现。
      return true;
    }
  }
  return false;
}
