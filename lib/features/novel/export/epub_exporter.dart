import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;

import '../../../core/models/chapter.dart';
import '../reader/novel_blocks.dart';

/// EPUB 导出结果。
class EpubExportResult {
  const EpubExportResult({
    required this.exportedChapters,
    required this.skippedChapters,
  });

  final int exportedChapters;
  final int skippedChapters;
}

/// 章节 → 正文（导出方负责取数，导出器只管打包）。
typedef ChapterContentResolver =
    Future<
      ({String title, String volumeTitle, String bodyHtml, String bodyText})?
    >
    Function(Chapter chapter);

/// 把已取回的章节打包为 EPUB 3（纯 Dart zip，无平台依赖）。
///
/// 付费章节由调用方过滤（[Chapter.locked]），导出器不做解锁、不绕过付费。
abstract final class EpubExporter {
  static Future<({Uint8List bytes, EpubExportResult result})> export({
    required String bookTitle,
    required String author,
    required String sourceId,
    required String remoteId,
    required String coverUrl,
    required List<Chapter> chapters,
    required ChapterContentResolver resolve,
    required void Function(int completed, int total) onProgress,
    Future<Uint8List?> Function(String url)? fetchImage,
  }) async {
    final usable = chapters.where((chapter) => !chapter.locked).toList();
    final resolved = <({Chapter chapter, String bodyHtml, String bodyText})>[];
    onProgress(0, usable.length);
    for (final chapter in usable) {
      final content = await resolve(chapter);
      if (content != null) {
        resolved.add((
          chapter: chapter,
          bodyHtml: content.bodyHtml,
          bodyText: content.bodyText,
        ));
      }
      onProgress(resolved.length, usable.length);
    }
    if (resolved.isEmpty) {
      throw StateError('没有可导出的章节（全部失败或全部为锁定章节）');
    }

    final assets = <String, Uint8List>{};
    final cover = coverUrl.isEmpty
        ? null
        : await _fetchImage(
            coverUrl,
            fetchImage,
            assets: assets,
            pathHint: 'cover',
          );
    final rewritten = <(Chapter, String)>[
      for (final entry in resolved)
        (
          entry.chapter,
          await _rewriteImages(
            entry.bodyHtml,
            entry.bodyText,
            fetchImage,
            assets,
          ),
        ),
    ];

    final archive = Archive();
    _putStored(archive, 'mimetype', utf8Bytes('application/epub+zip'));
    _putText(archive, 'META-INF/container.xml', _containerXml());
    _putText(archive, 'OEBPS/styles.css', _stylesheet);
    for (final entry in assets.entries) {
      _putBinary(archive, 'OEBPS/${entry.key}', entry.value);
    }
    for (var index = 0; index < rewritten.length; index++) {
      final (chapter, body) = rewritten[index];
      _putText(
        archive,
        _chapterPath(index),
        _chapterXhtml(bookTitle, chapter.title, body),
      );
    }
    _putText(archive, 'OEBPS/nav.xhtml', _navXhtml(bookTitle, rewritten));
    _putText(
      archive,
      'OEBPS/content.opf',
      _contentOpf(
        bookTitle: bookTitle,
        author: author,
        sourceId: sourceId,
        remoteId: remoteId,
        chapterCount: rewritten.length,
        assets: assets,
        coverPath: cover,
      ),
    );

    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    return (
      bytes: bytes,
      result: EpubExportResult(
        exportedChapters: rewritten.length,
        skippedChapters: chapters.length - rewritten.length,
      ),
    );
  }

  /// 下载封面并登记进资源表，返回包内路径（失败返回 null）。
  static Future<String?> _fetchImage(
    String url,
    Future<Uint8List?> Function(String)? fetchImage, {
    required Map<String, Uint8List> assets,
    required String pathHint,
  }) async {
    if (fetchImage == null) return null;
    try {
      final bytes = await fetchImage(url);
      if (bytes == null || bytes.isEmpty) return null;
      final path = 'images/$pathHint${_extensionOf(bytes)}';
      assets[path] = bytes;
      return path;
    } catch (_) {
      return null;
    }
  }

  static String _extensionOf(Uint8List bytes) => switch (_mediaTypeOf(bytes)) {
    'image/png' => '.png',
    'image/gif' => '.gif',
    'image/webp' => '.webp',
    _ => '.jpg',
  };

  static String _mediaTypeOf(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6) {
      final head = String.fromCharCodes(bytes.sublist(0, 6));
      if (head == 'GIF87a' || head == 'GIF89a') return 'image/gif';
    }
    if (bytes.length >= 12) {
      final head = String.fromCharCodes(bytes.sublist(0, 4));
      final marker = String.fromCharCodes(bytes.sublist(8, 12));
      if (head == 'RIFF' && marker == 'WEBP') return 'image/webp';
    }
    return 'image/jpeg';
  }

  /// 把正文里的远程插图下载进包内并重写地址（失败则保留原地址）。
  static Future<String> _rewriteImages(
    String bodyHtml,
    String bodyText,
    Future<Uint8List?> Function(String)? fetchImage,
    Map<String, Uint8List> assets,
  ) async {
    final blocks = ReaderContentParser.parse(
      bodyHtml: bodyHtml,
      bodyText: bodyText,
    );
    final buffer = StringBuffer();
    for (final block in blocks) {
      switch (block) {
        case HeadingBlock(:final text):
          buffer.write('<h2>${escapeXml(text)}</h2>');
        case ParagraphBlock(:final text, :final firstLineIndent):
          buffer.write(
            '<p${firstLineIndent ? ' class="indent"' : ''}>${escapeXml(text)}</p>',
          );
        case IllustrationBlock(:final url):
          var src = escapeXml(url);
          if (fetchImage != null) {
            try {
              final bytes = await fetchImage(url);
              if (bytes != null && bytes.isNotEmpty) {
                final name = 'images/image-${_hash(url)}${_extensionOf(bytes)}';
                assets.putIfAbsent(name, () => bytes);
                src = name;
              }
            } catch (_) {
              // 插图抓取失败不阻塞导出，保留原地址。
            }
          }
          buffer.write('<img src="$src"/>');
      }
    }
    return buffer.toString();
  }

  static String _hash(String value) =>
      crypto.sha256.convert(value.codeUnits).toString().substring(0, 16);

  static Uint8List utf8Bytes(String value) =>
      Uint8List.fromList(utf8.encode(value));

  static void _putStored(Archive archive, String path, Uint8List bytes) {
    // EPUB 规范要求 mimetype 条目不压缩（STORED）。
    final file = ArchiveFile.bytes(path, bytes)
      ..compression = CompressionType.none;
    archive.addFile(file);
  }

  static void _putText(Archive archive, String path, String value) {
    archive.addFile(ArchiveFile.bytes(path, utf8Bytes(value)));
  }

  static void _putBinary(Archive archive, String path, Uint8List bytes) {
    archive.addFile(ArchiveFile.bytes(path, bytes));
  }

  static String _chapterPath(int index) =>
      'OEBPS/chapter-${(index + 1).toString().padLeft(4, '0')}.xhtml';

  static String _chapterXhtml(
    String bookTitle,
    String chapterTitle,
    String body,
  ) =>
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE html>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">\n'
      '<head><title>${escapeXml(chapterTitle)}</title>'
      '<link rel="stylesheet" type="text/css" href="styles.css"/></head>\n'
      '<body><h1>${escapeXml(bookTitle)}</h1>'
      '<h2>${escapeXml(chapterTitle)}</h2>$body</body>\n'
      '</html>\n';

  static String _navXhtml(String title, List<(Chapter, String)> chapters) {
    final buffer = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">\n'
      '<head><title>${escapeXml(title)}</title></head>\n'
      '<body><nav epub:type="toc" id="toc"><h1>${escapeXml(title)}</h1><ol>\n',
    );
    for (var index = 0; index < chapters.length; index++) {
      final (chapter, _) = chapters[index];
      buffer.write(
        '<li><a href="${_chapterPath(index).split('/').last}">'
        '${escapeXml(chapter.title)}</a></li>\n',
      );
    }
    buffer.write('</ol></nav></body></html>\n');
    return buffer.toString();
  }

  static String _contentOpf({
    required String bookTitle,
    required String author,
    required String sourceId,
    required String remoteId,
    required int chapterCount,
    required Map<String, Uint8List> assets,
    required String? coverPath,
  }) {
    final buffer = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="book-id">\n'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="book-id">urn:triomi:$sourceId:$remoteId</dc:identifier>'
      '<dc:title>${escapeXml(bookTitle)}</dc:title>'
      '<dc:creator>${escapeXml(author.isEmpty ? '未知作者' : author)}</dc:creator>'
      '<dc:language>zh-CN</dc:language>'
      '<meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>'
      '</metadata>\n<manifest>\n'
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
      '<item id="css" href="styles.css" media-type="text/css"/>\n',
    );
    var assetIndex = 0;
    for (final path in assets.keys) {
      final mediaType = _mediaTypeOf(assets[path]!);
      final isCover = coverPath != null && path == coverPath;
      buffer.write(
        '<item id="asset-$assetIndex" href="$path" media-type="$mediaType"'
        '${isCover ? ' properties="cover-image"' : ''}/>\n',
      );
      assetIndex++;
    }
    for (var index = 0; index < chapterCount; index++) {
      buffer.write(
        '<item id="chapter-$index" href="${_chapterPath(index)}" '
        'media-type="application/xhtml+xml"/>\n',
      );
    }
    buffer.write('</manifest>\n<spine>\n');
    for (var index = 0; index < chapterCount; index++) {
      buffer.write('<itemref idref="chapter-$index"/>\n');
    }
    buffer.write('</spine>\n</package>\n');
    return buffer.toString();
  }

  static String _containerXml() =>
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles>'
      '</container>\n';

  static const String _stylesheet =
      'body { line-height: 1.65; }\n'
      'h1, h2 { text-align: center; }\n'
      'p { text-indent: 2em; margin: 0.4em 0; }\n'
      'p.indent { text-indent: 2em; }\n'
      'img { max-width: 100%; }\n';

  /// 测试用：把 zip 数据解开供断言。
  static Archive decode(Uint8List bytes) => ZipDecoder().decodeBytes(bytes);
}

/// 与 Mixn 对齐的 XML 转义。
String escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
