import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/platform/platform_channel.dart';
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
    this.savedToAuthorizedDirectory = false,
  });

  final String path;
  final int exportedChapters;
  final int skippedChapters;

  /// D50：true = 写入了用户授权的 SAF 目录；false = 应用导出目录
  /// （用户取消目录选择或授权目录写入失败后的回退）。
  final bool savedToAuthorizedDirectory;
}

/// 小说整书导出：取数（跳过锁定章节）→ 打包 → 写入导出目录。
abstract final class NovelExportService {
  /// EPUB 3：含目录、样式与封面/插图（抓取失败自动降级为外链）。
  ///
  /// [directoryUri] + [writeToTree]（D29）：用户授权目录（SAF）注入点，
  /// 契约与 `BackupService.exportToFile` 一致——提供时优先写入授权目录，
  /// 失败回退应用私有目录；两者都为空走私有目录。
  static Future<NovelExportResult> exportEpub({
    required MediaItem item,
    required List<Chapter> chapters,
    required ContentProvider source,
    required SourceHttpClient http,
    required void Function(int completed, int total) onProgress,
    String? directoryUri,
    SafTreeWriter? writeToTree,
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
    final written = await _writeOut(
      '${_safeName(item.title)}.epub',
      outcome.bytes,
      directoryUri: directoryUri,
      writeToTree: writeToTree,
    );
    return NovelExportResult(
      path: written.path,
      exportedChapters: outcome.result.exportedChapters,
      skippedChapters: outcome.result.skippedChapters,
      savedToAuthorizedDirectory: written.savedToTree,
    );
  }

  /// TXT：UTF-8 纯文本整书（SAF 注入语义同 [exportEpub]）。
  static Future<NovelExportResult> exportTxt({
    required MediaItem item,
    required List<Chapter> chapters,
    required ContentProvider source,
    required void Function(int completed, int total) onProgress,
    String? directoryUri,
    SafTreeWriter? writeToTree,
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
    final written = await _writeOut(
      '${_safeName(item.title)}.txt',
      utf8.encode(outcome.text),
      directoryUri: directoryUri,
      writeToTree: writeToTree,
    );
    return NovelExportResult(
      path: written.path,
      exportedChapters: outcome.result.exportedChapters,
      skippedChapters: outcome.result.skippedChapters,
      savedToAuthorizedDirectory: written.savedToTree,
    );
  }

  /// 导出目录：<文档>/exports/。
  static Future<Directory> exportDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}exports');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 统一写出：SAF 授权目录优先（提供注入器时），失败/未提供回退私有目录。
  ///
  /// SAF 路径没有目录列举能力，无法做同名冲突检测——由调用方（SAF 选择器）
  /// 决定目标文件名；私有目录回退保留 `(1)` 序号逻辑。
  static Future<({String path, bool savedToTree})> _writeOut(
    String name,
    List<int> bytes, {
    String? directoryUri,
    SafTreeWriter? writeToTree,
  }) async {
    if (directoryUri != null &&
        directoryUri.isNotEmpty &&
        writeToTree != null) {
      try {
        // 返回系统真实创建的 document URI（系统可能改名），不得合成路径。
        final documentUri = await writeToTree(directoryUri, name, bytes);
        if (documentUri.isNotEmpty) {
          return (path: documentUri, savedToTree: true);
        }
      } catch (_) {
        // 授权目录写入失败（权限被回收/磁盘满等）：回退私有目录。
      }
    }
    return (path: await _write(name, bytes), savedToTree: false);
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
