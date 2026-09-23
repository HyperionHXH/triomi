import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/source/http_client.dart';
import '../../../core/source/source_api.dart';
import 'epub_exporter.dart';
import 'txt_exporter.dart';

/// 导出汇总结果。
class NovelExportResult {
  const NovelExportResult({
    required this.path,
    required this.exportedChapters,
    required this.skippedChapters,
  });

  final String path;
  final int exportedChapters;
  final int skippedChapters;
}

/// 小说整书导出：取数（跳过锁定章节）→ 打包 → 写入导出目录。
abstract final class NovelExportService {
  /// EPUB 3：含目录、样式与封面/插图（抓取失败自动降级为外链）。
  static Future<NovelExportResult> exportEpub({
    required MediaItem item,
    required List<Chapter> chapters,
    required ContentProvider source,
    required SourceHttpClient http,
    required void Function(int completed, int total) onProgress,
  }) async {
    final outcome = await EpubExporter.export(
      bookTitle: item.title,
      author: item.author ?? '',
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      coverUrl: item.coverUrl ?? '',
      chapters: chapters,
      resolve: (chapter) async {
        final content = await source.content(chapter);
        if (content.isEmpty) return null;
        return (
          title: chapter.title,
          volumeTitle: chapter.volumeTitle ?? '',
          bodyHtml: content.html ?? '',
          bodyText: content.text ?? '',
        );
      },
      onProgress: onProgress,
      fetchImage: (url) async {
        try {
          final response = await http.fetchBytes(url, sourceId: item.sourceId);
          return Uint8List.fromList(response);
        } catch (_) {
          return null;
        }
      },
    );
    final path = await _write('${_safeName(item.title)}.epub', outcome.bytes);
    return NovelExportResult(
      path: path,
      exportedChapters: outcome.result.exportedChapters,
      skippedChapters: outcome.result.skippedChapters,
    );
  }

  /// TXT：UTF-8 纯文本整书。
  static Future<NovelExportResult> exportTxt({
    required MediaItem item,
    required List<Chapter> chapters,
    required ContentProvider source,
    required void Function(int completed, int total) onProgress,
  }) async {
    final outcome = await TxtExporter.exportText(
      bookTitle: item.title,
      author: item.author ?? '',
      chapters: chapters,
      resolve: (chapter) async {
        final content = await source.content(chapter);
        if (content.isEmpty) return null;
        return (bodyHtml: content.html ?? '', bodyText: content.text ?? '');
      },
      onProgress: onProgress,
    );
    final path = await _write(
      '${_safeName(item.title)}.txt',
      utf8.encode(outcome.text),
    );
    return NovelExportResult(
      path: path,
      exportedChapters: outcome.result.exportedChapters,
      skippedChapters: outcome.result.skippedChapters,
    );
  }

  /// 导出目录：<文档>/exports/。
  static Future<Directory> exportDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}exports');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<String> _write(String name, List<int> bytes) async {
    final dir = await exportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    var target = file;
    var attempt = 1;
    while (target.existsSync()) {
      final base = name.substring(0, name.lastIndexOf('.'));
      final ext = name.substring(name.lastIndexOf('.'));
      target = File(
        '${dir.path}${Platform.pathSeparator}$base(${attempt++})$ext',
      );
    }
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  static String _safeName(String title) => title
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
}
