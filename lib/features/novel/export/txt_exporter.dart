import '../../../core/models/chapter.dart';
import '../reader/novel_blocks.dart';

/// TXT 导出结果。
class TxtExportResult {
  const TxtExportResult({
    required this.exportedChapters,
    required this.skippedChapters,
  });

  final int exportedChapters;
  final int skippedChapters;
}

/// 章节正文（导出方负责取数）。
typedef TxtChapterResolver =
    Future<({String bodyHtml, String bodyText})?> Function(Chapter chapter);

/// 把已取回的章节写成 UTF-8 纯文本整书（格式对齐 Mixn 的 TxtExporter）。
abstract final class TxtExporter {
  /// 返回文本内容与统计（测试可以不落盘直接断言）。
  static Future<({String text, TxtExportResult result})> exportText({
    required String bookTitle,
    required String author,
    required List<Chapter> chapters,
    required TxtChapterResolver resolve,
    required void Function(int completed, int total) onProgress,
  }) async {
    final usable = chapters.where((chapter) => !chapter.locked).toList();
    final resolved = <(Chapter, String)>[];
    onProgress(0, usable.length);
    for (final chapter in usable) {
      final content = await resolve(chapter);
      if (content != null) {
        resolved.add((chapter, _plainText(content.bodyHtml, content.bodyText)));
      }
      onProgress(resolved.length, usable.length);
    }
    if (resolved.isEmpty) {
      throw StateError('没有可导出的章节（全部失败或全部为锁定章节）');
    }

    final buffer = StringBuffer()
      ..write(bookTitle.trim().isEmpty ? '未命名小说' : bookTitle.trim());
    if (author.trim().isNotEmpty) {
      buffer
        ..write('\n作者：')
        ..write(author.trim());
    }
    buffer.write('\n\n');
    for (var index = 0; index < resolved.length; index++) {
      final (chapter, text) = resolved[index];
      if (index > 0) buffer.write('\n\n');
      buffer
        ..write('【')
        ..write(
          chapter.volumeTitle?.trim().isNotEmpty == true
              ? chapter.volumeTitle!.trim()
              : '正文',
        )
        ..write('】\n')
        ..write(chapter.title)
        ..write('\n\n')
        ..write(text);
    }
    buffer.write('\n');

    final text = buffer.toString();
    return (
      text: text,
      result: TxtExportResult(
        exportedChapters: resolved.length,
        skippedChapters: chapters.length - resolved.length,
      ),
    );
  }

  /// HTML 转纯文本（对齐 Mixn：插图占位、块级标签换行、实体还原）。
  static String _plainText(String bodyHtml, String bodyText) {
    final blocks = ReaderContentParser.parse(
      bodyHtml: bodyHtml,
      bodyText: bodyText,
    );
    final lines = <String>[];
    for (final block in blocks) {
      switch (block) {
        case HeadingBlock(:final text):
          lines.add(text);
        case ParagraphBlock(:final text):
          lines.add(text);
        case IllustrationBlock():
          lines.add('[插图]');
      }
    }
    return lines.join('\n\n').trim();
  }
}
