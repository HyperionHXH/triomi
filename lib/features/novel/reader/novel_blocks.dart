import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 小说正文的排版块：标题 / 段落 / 插图。
///
/// 移植自 Mixn 的 ReaderBlock + ReaderContentParser（MIT，用户自有代码）。
sealed class ReaderBlock {
  const ReaderBlock();
}

class HeadingBlock extends ReaderBlock {
  const HeadingBlock(this.text);

  final String text;
}

class ParagraphBlock extends ReaderBlock {
  const ParagraphBlock(this.text, {this.firstLineIndent = true});

  final String text;

  /// 首行缩进两字符（LK 的 ln-paragraph--indent 或 CSS text-indent）。
  final bool firstLineIndent;
}

class IllustrationBlock extends ReaderBlock {
  const IllustrationBlock(this.url, {this.width, this.height});

  final String url;
  final int? width;
  final int? height;

  double get aspectRatio =>
      (width != null && height != null && width! > 0 && height! > 0)
      ? width! / height!
      : 0.72;
}

/// 把正文（HTML 或纯文本）解析成排版块。
abstract final class ReaderContentParser {
  static final RegExp _paragraphRegex = RegExp(
    r'<(p|h[1-6])([^>]*)>(.*?)</\1>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _imageRegex = RegExp(
    r'<img\b([^>]*)>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _tagRegex = RegExp(r'<[^>]+>');
  static final RegExp _breakTagRegex = RegExp(
    r'<br\s*/?>',
    caseSensitive: false,
  );
  static final RegExp _htmlEntityRegex = RegExp(
    r'&#(x[0-9a-f]+|[0-9]+);',
    caseSensitive: false,
  );
  // 注意：Dart 的 RegExp 里 `[^]]` 不是「非 ]」（与 Kotlin 不同），必须转义。
  static final RegExp _resourceTagRegex = RegExp(
    r'\[res\][^\]]*?\[/res\]',
    caseSensitive: false,
  );

  /// HTML 优先（保留插图），纯文本兜底。
  static List<ReaderBlock> parse({
    required String bodyHtml,
    required String bodyText,
  }) {
    final htmlBlocks = _parseHtml(bodyHtml);
    if (htmlBlocks.isNotEmpty) return htmlBlocks;

    final paragraphs = <ReaderBlock>[
      for (final line
          in bodyText
              .replaceAll(_resourceTagRegex, '\n【插图暂时无法加载】\n')
              .split('\n'))
        if (line.trim().isNotEmpty) ParagraphBlock(line.trim()),
    ];
    return paragraphs.isEmpty
        ? <ReaderBlock>[const ParagraphBlock('本章暂无正文', firstLineIndent: false)]
        : paragraphs;
  }

  static List<ReaderBlock> _parseHtml(String html) {
    if (html.trim().isEmpty) return const <ReaderBlock>[];
    final blocks = <ReaderBlock>[];

    // 按文档顺序合并两类事件：p/h1-h6 段落块，以及不在任何段落里的独立 img。
    final paragraphMatches = _paragraphRegex.allMatches(html).toList();
    final events = <(int, RegExpMatch, bool)>[
      for (final match in paragraphMatches) (match.start, match, true),
      for (final match in _imageRegex.allMatches(html))
        if (!paragraphMatches.any(
          (paragraph) =>
              match.start >= paragraph.start && match.end <= paragraph.end,
        ))
          (match.start, match, false),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    for (final (_, match, isParagraph) in events) {
      final tag = (match.group(1) ?? 'img').toLowerCase();
      if (!isParagraph) {
        final illustration = _toIllustration(match);
        if (illustration != null) blocks.add(illustration);
        continue;
      }
      final attributes = match.group(2) ?? '';
      final content = match.group(3) ?? '';
      if (tag != 'p') {
        final text = _stripTags(content).trim();
        if (text.isNotEmpty) blocks.add(HeadingBlock(text));
        continue;
      }
      final indent =
          attributes.toLowerCase().contains('text-indent') ||
          attributes.toLowerCase().contains('ln-paragraph--indent');
      _appendParagraphContent(blocks, content, indent);
    }
    if (blocks.isEmpty) _appendParagraphContent(blocks, html, false);
    return blocks;
  }

  static String _stripTags(String raw) => raw
      .replaceAll(_breakTagRegex, '\n')
      .replaceAll(_tagRegex, '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();

  static void _appendParagraphContent(
    List<ReaderBlock> out,
    String content,
    bool firstLineIndent,
  ) {
    var cursor = 0;
    var firstText = true;
    for (final match in _imageRegex.allMatches(content)) {
      _addText(
        out,
        content.substring(cursor, match.start),
        firstLineIndent && firstText,
      );
      firstText = false;
      final illustration = _toIllustration(match);
      if (illustration != null) out.add(illustration);
      cursor = match.end;
    }
    _addText(out, content.substring(cursor), firstLineIndent && firstText);
  }

  static void _addText(
    List<ReaderBlock> out,
    String raw,
    bool firstLineIndent,
  ) {
    final text = raw
        .replaceAll(_breakTagRegex, '\n')
        .replaceAll(_tagRegex, '')
        .replaceAllMapped(_htmlEntityRegex, (Match match) {
          final rawCode = match.group(1) ?? '';
          final code = rawCode.startsWith('x') || rawCode.startsWith('X')
              ? int.tryParse(rawCode.substring(1), radix: 16)
              : int.tryParse(rawCode);
          if (code == null || code < 0 || code > 0x10FFFF) {
            return match.group(0) ?? '';
          }
          return String.fromCharCode(code);
        })
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();
    if (text.isNotEmpty) {
      out.add(ParagraphBlock(text, firstLineIndent: firstLineIndent));
    }
  }

  static IllustrationBlock? _toIllustration(RegExpMatch match) {
    final attributes = match.group(1) ?? '';
    final src = <String>[
      for (final name in ['src', 'data-src', 'data-original', 'data-url'])
        if (_attribute(attributes, name) case final value?
            when value.trim().isNotEmpty)
          _toHttpsImageUrl(value.trim()),
    ].firstOrNull;
    if (src == null) return null;
    return IllustrationBlock(
      src,
      width: int.tryParse(
        _attribute(attributes, 'img-width') ??
            _attribute(attributes, 'width') ??
            '',
      ),
      height: int.tryParse(
        _attribute(attributes, 'img-height') ??
            _attribute(attributes, 'height') ??
            '',
      ),
    );
  }

  static String? _attribute(String attributes, String name) {
    final match = RegExp(
      '\\b${RegExp.escape(name)}\\s*=\\s*["\']([^"\']+)["\']',
      caseSensitive: false,
    ).firstMatch(attributes);
    return match?.group(1);
  }

  static String _toHttpsImageUrl(String value) {
    if (value.toLowerCase().startsWith('https://')) return value;
    if (value.toLowerCase().startsWith('http://')) {
      return 'https://${value.split('//').last}';
    }
    if (value.startsWith('//')) return 'https:$value';
    return value;
  }
}

/// 分页后的一个元素：文本片段或插图。
sealed class ReaderPageElement {
  const ReaderPageElement({required this.blockIndex});

  final int blockIndex;
}

class TextElement extends ReaderPageElement {
  const TextElement(
    this.text, {
    required this.heading,
    required this.firstLineIndent,
    required super.blockIndex,
  });

  final String text;
  final bool heading;
  final bool firstLineIndent;
}

class IllustrationElement extends ReaderPageElement {
  const IllustrationElement(
    this.block,
    this.heightPx, {
    required super.blockIndex,
  });

  final IllustrationBlock block;
  final double heightPx;
}

/// 分好页的一页。
class ReaderPage {
  const ReaderPage(this.elements);

  final List<ReaderPageElement> elements;
}

/// 分页参数（与阅读设置一一对应）。
class PaginationStyle {
  const PaginationStyle({
    required this.paragraphStyle,
    required this.headingStyle,
    required this.pageWidth,
    required this.pageHeight,
    required this.spacing,
  });

  final TextStyle paragraphStyle;
  final TextStyle headingStyle;

  /// 页面内容区宽度（逻辑像素，已扣除页边距）。
  final double pageWidth;
  final double pageHeight;

  /// 段间距。
  final double spacing;
}

/// 把排版块切成页：跨页段落会按行切断，插图放不下就顺延到下一页。
///
/// 算法移植自 Mixn 的 `paginateReaderBlocks`（TextMeasurer → TextPainter）。
List<ReaderPage> paginateReaderBlocks(
  List<ReaderBlock> blocks,
  PaginationStyle style,
) {
  if (style.pageWidth <= 0 || style.pageHeight <= 0) {
    return const <ReaderPage>[];
  }

  final pages = <ReaderPage>[];
  var elements = <ReaderPageElement>[];
  var remainingHeight = style.pageHeight;

  void finishPage() {
    if (elements.isEmpty) return;
    pages.add(ReaderPage(List<ReaderPageElement>.of(elements)));
    elements = <ReaderPageElement>[];
    remainingHeight = style.pageHeight;
  }

  void reserveSpacing(double minimumContentHeight) {
    if (elements.isEmpty) return;
    if (remainingHeight - style.spacing < minimumContentHeight) {
      finishPage();
    } else {
      remainingHeight -= style.spacing;
    }
  }

  for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++) {
    final block = blocks[blockIndex];

    if (block is IllustrationBlock) {
      final desiredHeight = math.min(
        style.pageWidth / block.aspectRatio,
        style.pageHeight,
      );
      reserveSpacing(desiredHeight);
      if (remainingHeight <= 0) finishPage();
      final imageHeight = math
          .min(desiredHeight, remainingHeight)
          .clamp(1.0, style.pageHeight);
      elements.add(
        IllustrationElement(block, imageHeight, blockIndex: blockIndex),
      );
      remainingHeight = math.max(remainingHeight - imageHeight, 0);
      continue;
    }

    // Heading / Paragraph
    final heading = block is HeadingBlock;
    final sourceText = block is HeadingBlock
        ? block.text
        : (block as ParagraphBlock).text;
    final shouldIndent = block is ParagraphBlock && block.firstLineIndent;
    final baseStyle = heading ? style.headingStyle : style.paragraphStyle;
    final lineHeight = baseStyle.fontSize! * (baseStyle.height ?? 1.5);
    var offset = 0;

    while (offset < sourceText.length) {
      reserveSpacing(lineHeight);
      if (remainingHeight < lineHeight) finishPage();
      final maxLines = math.max((remainingHeight / lineHeight).floor(), 1);
      final indentThisFragment = shouldIndent && offset == 0;

      // 首行缩进用两个全角空格近似（TextPainter 没有 textIndent）；
      // 缩进前缀参与测量，保证行数计算与显示一致。
      final remainingText = indentThisFragment
          ? '　　${sourceText.substring(offset)}'
          : sourceText.substring(offset);
      final painter = TextPainter(
        text: TextSpan(text: remainingText, style: baseStyle),
        textDirection: TextDirection.ltr,
        maxLines: maxLines,
        textScaler: TextScaler.noScaling,
      )..layout(maxWidth: style.pageWidth);

      // 取最后一行行尾的字符位置：命中最后一行的右端
      // （整行则行尾，残行则文本末尾）。x 取行中点会命中行中间字符，
      // 导致每个段落都被切成两半。
      final lineMetrics = painter.computeLineMetrics();
      final lastLine = lineMetrics.last;
      final end = painter
          .getPositionForOffset(Offset(style.pageWidth, lastLine.baseline))
          .offset;
      final safeEnd = math.max(math.min(end, remainingText.length), 1);

      elements.add(
        TextElement(
          remainingText.substring(0, safeEnd),
          heading: heading,
          firstLineIndent: indentThisFragment,
          blockIndex: blockIndex,
        ),
      );
      remainingHeight = math.max(remainingHeight - painter.height, 0);
      offset += safeEnd - (indentThisFragment ? 2 : 0);
      if (offset < sourceText.length) finishPage();
    }
  }
  finishPage();

  return pages.isEmpty
      ? <ReaderPage>[const ReaderPage(<ReaderPageElement>[])]
      : pages;
}
